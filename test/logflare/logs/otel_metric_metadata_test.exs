defmodule Logflare.Logs.OtelMetricMetadataTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelMetric
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogram
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint.Buckets
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Histogram
  alias Opentelemetry.Proto.Metrics.V1.HistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Sum

  test "preserves metric descriptions and metadata without overwriting event fields" do
    number = %NumberDataPoint{value: {:as_int, 7}}
    attributes = [%KeyValue{key: "type", value: %AnyValue{value: {:string_value, "custom"}}}]
    resource = %{"service.name" => "app"}
    scope = %{"name" => "library"}

    for data <- [
          {:gauge, %Gauge{data_points: [number]}},
          {:sum, %Sum{data_points: [number]}},
          {:histogram, %Histogram{data_points: [%HistogramDataPoint{count: 1}]}},
          {:exponential_histogram,
           %ExponentialHistogram{
             data_points: [
               %ExponentialHistogramDataPoint{
                 count: 1,
                 positive: %Buckets{},
                 negative: %Buckets{}
               }
             ]
           }}
        ] do
      metric = %Metric{
        name: "request.duration",
        unit: "ms",
        description: "request duration",
        metadata: attributes,
        data: data
      }

      assert [event] = OtelMetric.handle_metric(metric, resource, scope)
      assert event["description"] == "request duration"
      assert event["metric_metadata"] == %{"type" => "custom"}
      assert event["metadata"] == %{"type" => "metric"}
      assert event["event_message"] == "request.duration"
      assert event["unit"] == "ms"
      assert event["resource"] == resource
      assert event["scope"] == scope
      assert event["project"] == "app"
    end
  end
end
