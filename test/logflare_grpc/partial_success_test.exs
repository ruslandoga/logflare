defmodule LogflareGrpc.PartialSuccessTest do
  use Logflare.DataCase, async: false

  alias Logflare.Backends

  setup do
    insert(:plan)
    user = insert(:user)
    source = insert(:source, user: user)
    access_token = insert(:access_token, resource_owner: user, scopes: "ingest")

    start_supervised!(GRPC.Client.Supervisor)
    {:ok, _pid, port} = GRPC.Server.start_endpoint(LogflareGrpc.Endpoint, 0)
    on_exit(fn -> GRPC.Server.stop_endpoint(LogflareGrpc.Endpoint) end)

    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}",
        headers: [{"x-api-key", access_token.token}, {"x-source", source.token}]
      )

    Mimic.stub(Backends, :start_for_ingest, fn _source -> :ok end)
    %{channel: channel}
  end

  for {signal, stub, request_function, count_field} <- [
        {:logs, Opentelemetry.Proto.Collector.Logs.V1.LogsService.Stub, :random_otel_logs_request,
         :rejected_log_records},
        {:metrics, Opentelemetry.Proto.Collector.Metrics.V1.MetricsService.Stub,
         :random_otel_metrics_request, :rejected_data_points},
        {:traces, Opentelemetry.Proto.Collector.Trace.V1.TraceService.Stub,
         :random_export_service_request, :rejected_spans}
      ] do
    test "#{signal} reports rejected input units with a successful gRPC status", %{
      channel: channel
    } do
      Mimic.stub(Backends, :ingest_logs_with_rejections, fn batch, _source, nil, true ->
        indices = if unquote(signal) == :traces, do: [0, 1], else: [0]
        rejections = Enum.map(indices, &{&1, "invalid value"})
        {:ok, %{accepted: length(batch) - length(indices), rejections: rejections}}
      end)

      request = apply(TestUtilsGrpc, unquote(request_function), [])
      assert {:ok, response} = unquote(stub).export(channel, request)
      assert Map.fetch!(response.partial_success, unquote(count_field)) == 1
      assert response.partial_success.error_message == "invalid value"
    end

    test "#{signal} reports all-rejected batches without a retryable status", %{channel: channel} do
      Mimic.stub(Backends, :ingest_logs_with_rejections, fn batch, _source, nil, true ->
        rejections = for {_event, index} <- Enum.with_index(batch), do: {index, "invalid value"}
        {:ok, %{accepted: 0, rejections: rejections}}
      end)

      request = apply(TestUtilsGrpc, unquote(request_function), [])
      expected = request_unit_count(request, unquote(signal))

      assert {:ok, response} = unquote(stub).export(channel, request)
      assert Map.fetch!(response.partial_success, unquote(count_field)) == expected
    end

    test "#{signal} leaves partial_success absent when every unit is accepted", %{
      channel: channel
    } do
      Mimic.stub(Backends, :ingest_logs_with_rejections, fn batch, _source, nil, true ->
        {:ok, %{accepted: length(batch), rejections: []}}
      end)

      request = apply(TestUtilsGrpc, unquote(request_function), [])
      assert {:ok, %{partial_success: nil}} = unquote(stub).export(channel, request)
    end
  end

  @spec request_unit_count(struct(), :logs | :metrics | :traces) :: non_neg_integer()
  defp request_unit_count(request, :logs) do
    for resource <- request.resource_logs,
        scope <- resource.scope_logs,
        record <- scope.log_records do
      record
    end
    |> length()
  end

  defp request_unit_count(request, :metrics) do
    for resource <- request.resource_metrics,
        scope <- resource.scope_metrics,
        metric <- scope.metrics,
        {_type, data} = metric.data,
        point <- data.data_points do
      point
    end
    |> length()
  end

  defp request_unit_count(request, :traces) do
    for resource <- request.resource_spans, scope <- resource.scope_spans, span <- scope.spans do
      span
    end
    |> length()
  end
end
