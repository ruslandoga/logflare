defmodule Logflare.Logs.OtelMetricRejectionsTest do
  use LogflareWeb.ConnCase, async: false

  alias Logflare.Backends
  alias Logflare.Logs.OtelMetric
  alias Logflare.Logs.Processor
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceResponse
  alias Opentelemetry.Proto.Collector.Metrics.V1.MetricsService.Stub
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogram
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Histogram
  alias Opentelemetry.Proto.Metrics.V1.HistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ResourceMetrics
  alias Opentelemetry.Proto.Metrics.V1.ScopeMetrics
  alias Opentelemetry.Proto.Metrics.V1.Sum
  alias Opentelemetry.Proto.Metrics.V1.Summary
  alias Opentelemetry.Proto.Metrics.V1.SummaryDataPoint

  @moduletag capture_log: true

  setup do
    insert(:plan)
    user = insert(:user)
    source = insert(:source, user: user)
    Mimic.stub(Backends, :start_for_ingest, fn _source -> :ok end)
    %{user: user, source: source}
  end

  test "reports unset number values and unsupported summary points without changing legacy output" do
    resources = mixed_request().resource_metrics
    {events, report} = OtelMetric.handle_batch_with_report(resources, nil)

    assert Enum.map(events, & &1["value"]) === [0, 0.0]
    assert report.rejected == 3
    assert Enum.count(report.errors, &String.contains?(&1, "numeric")) == 2
    assert Enum.count(report.errors, &String.contains?(&1, "summary")) == 1
    assert OtelMetric.handle_batch(resources, nil) === events
  end

  test "does not reject intentionally omitted staleness markers for any metric type" do
    metrics = [
      %Metric{data: {:gauge, %Gauge{data_points: [%NumberDataPoint{flags: 1}]}}},
      %Metric{data: {:sum, %Sum{data_points: [%NumberDataPoint{flags: 3}]}}},
      %Metric{data: {:histogram, %Histogram{data_points: [%HistogramDataPoint{flags: 1}]}}},
      %Metric{
        data:
          {:exponential_histogram,
           %ExponentialHistogram{data_points: [%ExponentialHistogramDataPoint{flags: 1}]}}
      },
      %Metric{data: {:summary, %Summary{data_points: [%SummaryDataPoint{flags: 1}]}}}
    ]

    assert {[], %{rejected: 0, errors: []}} =
             OtelMetric.handle_batch_with_report(metrics_request(metrics).resource_metrics, nil)
  end

  test "empty envelopes, unset metric data, and empty unsupported metrics have no rejected points" do
    resources =
      metrics_request([%Metric{}, %Metric{data: {:summary, %Summary{}}}]).resource_metrics

    assert {[], %{rejected: 0, errors: []}} = OtelMetric.handle_batch_with_report([], nil)
    assert {[], %{rejected: 0, errors: []}} = OtelMetric.handle_batch_with_report(resources, nil)
  end

  test "adds converter and backend rejections once and preserves dispatch failures and legacy results",
       %{
         source: source
       } do
    resources = mixed_request().resource_metrics

    Mimic.stub(Backends, :ingest_logs_with_rejections, fn batch, ^source, nil, true ->
      assert Enum.map(batch, & &1["value"]) === [0, 0.0]
      {:ok, %{accepted: 1, rejections: [{0, "backend validation rejected the zero"}]}}
    end)

    assert {:ok, %{rejected: 4, errors: errors}} =
             Processor.ingest_with_report(resources, OtelMetric, source)

    assert length(errors) == 4
    assert List.last(errors) == "backend validation rejected the zero"

    Mimic.stub(Backends, :ingest_logs_with_rejections, fn _batch, ^source, nil, true ->
      {:error, :spool_unavailable}
    end)

    assert {:error, :spool_unavailable} =
             Processor.ingest_with_report(resources, OtelMetric, source)

    Mimic.stub(Backends, :ingest_logs, fn batch, ^source, nil, true -> {:ok, length(batch)} end)
    assert {:ok, 2} = Processor.ingest(resources, OtelMetric, source)
  end

  for transport <- [:http, :grpc] do
    test "#{transport} reports converter rejections while accepting valid metric siblings",
         context do
      Mimic.stub(Backends, :ingest_logs_with_rejections, fn batch, _source, nil, true ->
        assert Enum.map(batch, & &1["value"]) === [0, 0.0]
        {:ok, %{accepted: 2, rejections: []}}
      end)

      response = export_request(mixed_request(), unquote(transport), context)
      assert response.partial_success.rejected_data_points == 3
      assert response.partial_success.error_message =~ "numeric"
      assert response.partial_success.error_message =~ "summary"
    end

    test "#{transport} reports an entirely rejected preconversion batch", context do
      Mimic.stub(Backends, :ingest_logs_with_rejections, fn [], _source, nil, true ->
        {:ok, %{accepted: 0, rejections: []}}
      end)

      request =
        metrics_request([
          %Metric{data: {:gauge, %Gauge{data_points: [%NumberDataPoint{}]}}},
          %Metric{data: {:summary, %Summary{data_points: [%SummaryDataPoint{}]}}}
        ])

      response = export_request(request, unquote(transport), context)
      assert response.partial_success.rejected_data_points == 2
    end
  end

  @spec mixed_request() :: ExportMetricsServiceRequest.t()
  defp mixed_request do
    metrics_request([
      %Metric{
        data:
          {:gauge,
           %Gauge{
             data_points: [
               %NumberDataPoint{},
               %NumberDataPoint{value: {:as_int, 0}},
               %NumberDataPoint{flags: 1}
             ]
           }}
      },
      %Metric{
        data:
          {:sum,
           %Sum{data_points: [%NumberDataPoint{}, %NumberDataPoint{value: {:as_double, 0.0}}]}}
      },
      %Metric{
        data:
          {:summary, %Summary{data_points: [%SummaryDataPoint{}, %SummaryDataPoint{flags: 1}]}}
      },
      %Metric{}
    ])
  end

  @spec metrics_request([Metric.t()]) :: ExportMetricsServiceRequest.t()
  defp metrics_request(metrics) do
    %ExportMetricsServiceRequest{
      resource_metrics: [%ResourceMetrics{scope_metrics: [%ScopeMetrics{metrics: metrics}]}]
    }
  end

  @spec export_request(ExportMetricsServiceRequest.t(), :http | :grpc, map()) ::
          ExportMetricsServiceResponse.t()
  defp export_request(request, :http, %{conn: conn, user: user, source: source}) do
    conn =
      conn
      |> put_req_header("x-api-key", user.api_key)
      |> put_req_header("x-source", Atom.to_string(source.token))
      |> put_req_header("content-type", "application/x-protobuf")
      |> post(Routes.log_path(conn, :otel_metrics), ExportMetricsServiceRequest.encode(request))

    assert conn.status == 200
    ExportMetricsServiceResponse.decode(conn.resp_body)
  end

  defp export_request(request, :grpc, %{user: user, source: source}) do
    access_token = insert(:access_token, resource_owner: user, scopes: "ingest")
    start_supervised!(GRPC.Client.Supervisor)
    {:ok, _pid, port} = GRPC.Server.start_endpoint(LogflareGrpc.Endpoint, 0)
    on_exit(fn -> GRPC.Server.stop_endpoint(LogflareGrpc.Endpoint) end)

    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}",
        headers: [{"x-api-key", access_token.token}, {"x-source", Atom.to_string(source.token)}]
      )

    assert {:ok, response} = Stub.export(channel, request)
    response
  end
end
