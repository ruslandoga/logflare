defmodule Logflare.Logs.OtelMetricTemporalityTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelMetric
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogram
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint.Buckets
  alias Opentelemetry.Proto.Metrics.V1.Histogram
  alias Opentelemetry.Proto.Metrics.V1.HistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Sum

  test "accepts integer and unknown aggregation enum values while preserving protobuf atom behavior" do
    for {temporality, expected} <- [
          {0, "unspecified"},
          {1, "delta"},
          {2, "cumulative"},
          {99, "unspecified"}
        ],
        data <- [
          {:sum,
           %Sum{
             aggregation_temporality: temporality,
             data_points: [%NumberDataPoint{value: {:as_int, 1}}]
           }},
          {:histogram,
           %Histogram{
             aggregation_temporality: temporality,
             data_points: [%HistogramDataPoint{count: 1}]
           }},
          {:exponential_histogram,
           %ExponentialHistogram{
             aggregation_temporality: temporality,
             data_points: [
               %ExponentialHistogramDataPoint{
                 count: 1,
                 zero_count: 1,
                 positive: %Buckets{},
                 negative: %Buckets{}
               }
             ]
           }}
        ] do
      metric = %Metric{data: data}

      assert [event] = OtelMetric.handle_metric(metric, %{}, %{})
      assert event["aggregation_temporality"] == expected

      decoded_metric = metric |> Metric.encode() |> Metric.decode()
      assert [^event] = OtelMetric.handle_metric(decoded_metric, %{}, %{})
    end
  end
end
