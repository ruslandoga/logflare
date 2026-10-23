defmodule Logflare.Logs.OtelEnvelopeMetadataTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelLog
  alias Logflare.Logs.OtelMetric
  alias Logflare.Logs.OtelTrace
  alias Logflare.Mapper
  alias Logflare.Mapper.OtelDefaults
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias Opentelemetry.Proto.Common.V1.KeyValue
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

  test "all signals preserve schema URLs separately from user attributes and retain drop counts" do
    attribute = %KeyValue{key: "schema_url", value: %AnyValue{value: {:string_value, "custom"}}}
    resource = %Resource{attributes: [attribute], dropped_attributes_count: 3}
    scope = %InstrumentationScope{attributes: [attribute], dropped_attributes_count: 4}

    envelopes = [
      {OtelLog,
       %ResourceLogs{
         resource: resource,
         schema_url: "resource-schema",
         scope_logs: [
           %ScopeLogs{scope: scope, schema_url: "scope-schema", log_records: [%LogRecord{}]}
         ]
       }},
      {OtelMetric,
       %ResourceMetrics{
         resource: resource,
         schema_url: "resource-schema",
         scope_metrics: [
           %ScopeMetrics{
             scope: scope,
             schema_url: "scope-schema",
             metrics: [
               %Metric{
                 data: {:gauge, %Gauge{data_points: [%NumberDataPoint{value: {:as_int, 1}}]}}
               }
             ]
           }
         ]
       }},
      {OtelTrace,
       %ResourceSpans{
         resource: resource,
         schema_url: "resource-schema",
         scope_spans: [%ScopeSpans{scope: scope, schema_url: "scope-schema", spans: [%Span{}]}]
       }}
    ]

    for {converter, envelope} <- envelopes do
      assert [
               %{
                 "resource_schema_url" => "resource-schema",
                 "scope_schema_url" => "scope-schema",
                 "resource_dropped_attributes_count" => 3,
                 "resource" => %{"schema_url" => "custom"},
                 "scope" => %{
                   "dropped_attributes_count" => 4,
                   "attributes" => %{"schema_url" => "custom"}
                 }
               }
             ] = converter.handle_batch([envelope], nil)
    end
  end

  test "default log and metric mappers prefer canonical URLs and retain legacy fallbacks" do
    for type <- [:log, :metric] do
      compiled = Mapper.compile!(OtelDefaults.for_type(type, :map))

      legacy = %{
        "timestamp" => 0,
        "resource" => %{"schema_url" => "legacy-resource"},
        "scope" => %{"schema_url" => "legacy-scope"}
      }

      assert %{"resource_schema_url" => "legacy-resource", "scope_schema_url" => "legacy-scope"} =
               Mapper.map(legacy, compiled)

      canonical =
        Map.merge(legacy, %{
          "resource_schema_url" => "resource-schema",
          "scope_schema_url" => "scope-schema"
        })

      assert %{"resource_schema_url" => "resource-schema", "scope_schema_url" => "scope-schema"} =
               Mapper.map(canonical, compiled)
    end
  end
end
