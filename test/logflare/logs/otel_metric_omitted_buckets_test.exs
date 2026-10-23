defmodule Logflare.Logs.OtelMetricOmittedBucketsTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelMetric
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogram
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint.Buckets
  alias Opentelemetry.Proto.Metrics.V1.Metric

  test "accepts omitted exponential histogram buckets and preserves populated buckets" do
    buckets = %Buckets{offset: -2, bucket_counts: [1, 0, 2]}

    points = [
      %ExponentialHistogramDataPoint{count: 3, positive: buckets},
      %ExponentialHistogramDataPoint{count: 3, negative: buckets},
      %ExponentialHistogramDataPoint{count: 1, zero_count: 1}
    ]

    metric = %Metric{data: {:exponential_histogram, %ExponentialHistogram{data_points: points}}}
    populated = %{"offset" => -2, "bucket_counts" => [1, 0, 2]}
    empty = %{"offset" => 0, "bucket_counts" => []}

    assert [positive, negative, zero] = OtelMetric.handle_metric(metric, %{}, %{})
    assert positive["positive"] == populated
    assert positive["negative"] == empty
    assert negative["positive"] == empty
    assert negative["negative"] == populated
    assert zero["positive"] == empty
    assert zero["negative"] == empty
  end
end
