defmodule Logflare.Logs.OtelOptionalContextTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.Otel
  alias Logflare.Logs.OtelLog
  alias Logflare.Logs.OtelMetric
  alias Logflare.Logs.OtelTrace
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias Opentelemetry.Proto.Logs.V1.LogRecord
  alias Opentelemetry.Proto.Logs.V1.ResourceLogs
  alias Opentelemetry.Proto.Logs.V1.ScopeLogs
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ResourceMetrics
  alias Opentelemetry.Proto.Metrics.V1.ScopeMetrics
  alias Opentelemetry.Proto.Resource.V1.Resource
  alias Opentelemetry.Proto.Trace.V1.ResourceSpans
  alias Opentelemetry.Proto.Trace.V1.ScopeSpans
  alias Opentelemetry.Proto.Trace.V1.Span

  test "omitted context is equivalent to an empty protobuf message" do
    assert Otel.handle_resource(nil) == Otel.handle_resource(%Resource{})
    assert Otel.handle_scope(nil) == Otel.handle_scope(%InstrumentationScope{})
  end

  test "all three signals accept omitted resources and scopes" do
    batches = [
      {OtelLog, %ResourceLogs{scope_logs: [%ScopeLogs{log_records: [%LogRecord{}]}]}},
      {OtelMetric,
       %ResourceMetrics{
         scope_metrics: [
           %ScopeMetrics{
             metrics: [
               %Metric{
                 data: {:gauge, %Gauge{data_points: [%NumberDataPoint{value: {:as_int, 1}}]}}
               }
             ]
           }
         ]
       }},
      {OtelTrace, %ResourceSpans{scope_spans: [%ScopeSpans{spans: [%Span{name: "span"}]}]}}
    ]

    for {converter, envelope} <- batches do
      assert [%{"resource" => %{}, "scope" => scope}] = converter.handle_batch([envelope], nil)
      assert %{"name" => "", "version" => "", "attributes" => %{}} = scope
    end
  end

  test "empty resource and scope envelopes produce no records" do
    for {converter, envelopes} <- [
          {OtelLog, [%ResourceLogs{}, %ResourceLogs{scope_logs: [%ScopeLogs{}]}]},
          {OtelMetric, [%ResourceMetrics{}, %ResourceMetrics{scope_metrics: [%ScopeMetrics{}]}]},
          {OtelTrace, [%ResourceSpans{}, %ResourceSpans{scope_spans: [%ScopeSpans{}]}]}
        ] do
      assert converter.handle_batch(envelopes, nil) == []
    end
  end
end
