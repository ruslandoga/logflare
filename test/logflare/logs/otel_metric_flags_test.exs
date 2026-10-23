defmodule Logflare.Logs.OtelMetricFlagsTest do
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

  test "filters the no-recorded-value bit and preserves other flag bits for all metric types" do
    flags = [1, 3, 0, 2]
    number_points = for flag <- flags, do: %NumberDataPoint{flags: flag, value: {:as_int, flag}}
    histogram_points = for flag <- flags, do: %HistogramDataPoint{flags: flag, count: flag}

    exponential_points =
      for flag <- flags do
        %ExponentialHistogramDataPoint{
          flags: flag,
          count: flag,
          positive: %Buckets{},
          negative: %Buckets{}
        }
      end

    for {data, field} <- [
          {{:gauge, %Gauge{data_points: number_points}}, "value"},
          {{:sum, %Sum{data_points: number_points}}, "value"},
          {{:histogram, %Histogram{data_points: histogram_points}}, "count"},
          {{:exponential_histogram, %ExponentialHistogram{data_points: exponential_points}},
           "count"}
        ] do
      events = OtelMetric.handle_metric(%Metric{data: data}, %{}, %{})

      assert Enum.map(events, & &1[field]) == [0, 2]
      assert Enum.map(events, & &1["flags"]) == [0, 2]
    end
  end

  test "ignores unrecorded number points even when their value is absent" do
    points = [%NumberDataPoint{flags: 1}, %NumberDataPoint{value: {:as_int, 5}}]
    metric = %Metric{data: {:gauge, %Gauge{data_points: points}}}

    assert [%{"value" => 5}] = OtelMetric.handle_metric(metric, %{}, %{})
  end
end
