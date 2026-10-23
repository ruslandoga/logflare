defmodule LogflareGrpc.IngestResponseTest do
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

  for {signal, stub, request_function} <- [
        {:logs, Opentelemetry.Proto.Collector.Logs.V1.LogsService.Stub,
         :random_otel_logs_request},
        {:metrics, Opentelemetry.Proto.Collector.Metrics.V1.MetricsService.Stub,
         :random_otel_metrics_request},
        {:traces, Opentelemetry.Proto.Collector.Trace.V1.TraceService.Stub,
         :random_export_service_request}
      ] do
    test "#{signal} returns UNAVAILABLE when the spool producer fails", %{channel: channel} do
      Mimic.stub(Backends, :ingest_logs, fn _batch, _source, _backend, true ->
        {:error, :spool_unavailable}
      end)

      request = apply(TestUtilsGrpc, unquote(request_function), [])
      unavailable = GRPC.Status.unavailable()

      assert {:error, %GRPC.RPCError{status: ^unavailable}} =
               unquote(stub).export(channel, request)
    end

    test "#{signal} returns INTERNAL for an unexpected ingest failure", %{channel: channel} do
      Mimic.stub(Backends, :ingest_logs, fn _batch, _source, _backend, true ->
        {:error, :unexpected_failure}
      end)

      request = apply(TestUtilsGrpc, unquote(request_function), [])
      internal = GRPC.Status.internal()

      assert {:error, %GRPC.RPCError{status: ^internal}} =
               unquote(stub).export(channel, request)
    end
  end
end
