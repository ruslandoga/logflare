defmodule Logflare.Logs.OtelMetricZeroCountTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelMetric
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogram
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint.Buckets
  alias Opentelemetry.Proto.Metrics.V1.Metric

  test "preserves zero_count independently of exponential histogram scale" do
    for {scale, zero_count} <- [{-3, 17}, {0, 0}, {4, 1}] do
      point = %ExponentialHistogramDataPoint{
        count: zero_count,
        scale: scale,
        zero_count: zero_count,
        positive: %Buckets{},
        negative: %Buckets{}
      }

      metric = %Metric{
        data: {:exponential_histogram, %ExponentialHistogram{data_points: [point]}}
      }

      assert [event] = OtelMetric.handle_metric(metric, %{}, %{})
      assert event["zero_count"] == zero_count
      assert event["scale"] == scale
      assert event["count"] == zero_count
    end
  end
end
