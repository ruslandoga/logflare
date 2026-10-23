defmodule Logflare.Logs.OtelMetricNonfiniteTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelMetric
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogram
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint.Buckets
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Histogram
  alias Opentelemetry.Proto.Metrics.V1.HistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Sum

  test "normalizes non-finite gauge and sum values while preserving finite number types" do
    for {type, value, expected} <- [
          {:as_double, :nan, "NaN"},
          {:as_double, :infinity, "Infinity"},
          {:as_double, :negative_infinity, "-Infinity"},
          {:as_int, 0, 0},
          {:as_double, 0.0, 0.0}
        ],
        data <- [
          {:gauge, %Gauge{data_points: [%NumberDataPoint{value: {type, value}}]}},
          {:sum, %Sum{data_points: [%NumberDataPoint{value: {type, value}}]}}
        ] do
      assert [event] = OtelMetric.handle_metric(%Metric{data: data}, %{}, %{})
      assert event["value"] === expected
      assert {:ok, _} = Jason.encode(event)
    end
  end

  test "normalizes histogram doubles and preserves absent optional fields" do
    point = %HistogramDataPoint{
      sum: :infinity,
      min: :negative_infinity,
      max: :nan,
      explicit_bounds: [:infinity]
    }

    metric = %Metric{data: {:histogram, %Histogram{data_points: [point, %HistogramDataPoint{}]}}}

    assert [event, absent] = OtelMetric.handle_metric(metric, %{}, %{})
    assert event["sum"] == "Infinity"
    assert event["min"] == "-Infinity"
    assert event["max"] == "NaN"
    assert event["explicit_bounds"] == ["Infinity"]
    assert absent["sum"] == nil
    assert absent["min"] == nil
    assert absent["max"] == nil
  end

  test "normalizes exponential histogram doubles" do
    point = %ExponentialHistogramDataPoint{
      sum: :infinity,
      min: :negative_infinity,
      max: :nan,
      zero_threshold: :infinity,
      positive: %Buckets{},
      negative: %Buckets{}
    }

    metric = %Metric{data: {:exponential_histogram, %ExponentialHistogram{data_points: [point]}}}

    assert [event] = OtelMetric.handle_metric(metric, %{}, %{})
    assert event["sum"] == "Infinity"
    assert event["min"] == "-Infinity"
    assert event["max"] == "NaN"
    assert event["zero_threshold"] == "Infinity"
  end
end
