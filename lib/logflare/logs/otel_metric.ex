defmodule Logflare.Logs.OtelMetric do
  @moduledoc """
  Converts a list of Otel ResourceMetrics to a list of Logflare events

  * One ResourceMetric can contain multiple ScopeSpans
  * One ScopeMetrics can contain multiple Metrics
  * One Metric can contain multiple DataPoints
  * A Log Event is created for each DataPoint, including parent metric data

  Supports gauges, sums, histograms and exponential histograms. Summaries aren't
  supported. Data points marked `NO_RECORDED_VALUE` are omitted because they
  represent missing observations rather than numeric samples.
  """

  require Logger

  alias Logflare.Logs.Otel

  @behaviour Logflare.Logs.Processor

  def handle_batch(resource_metrics, _source) when is_list(resource_metrics) do
    resource_metrics
    |> Enum.flat_map(&handle_resource_metrics(&1))
  end

  def handle_resource_metrics(%_resource_metrics{
        resource: resource,
        scope_metrics: scope_metrics,
        schema_url: resource_schema_url
      }) do
    resource_dropped_attributes_count = Map.get(resource || %{}, :dropped_attributes_count, 0)
    resource = Otel.handle_resource(resource)

    Enum.flat_map(scope_metrics, fn scope_metric ->
      scope = Otel.handle_scope(scope_metric.scope)

      metadata = %{
        "resource_schema_url" => resource_schema_url,
        "scope_schema_url" => scope_metric.schema_url,
        "resource_dropped_attributes_count" => resource_dropped_attributes_count
      }

      Enum.flat_map(scope_metric.metrics, fn metric ->
        metric
        |> handle_metric(resource, scope)
        |> Enum.map(&Map.merge(&1, metadata))
      end)
    end)
  end

  def handle_metric(%_metric{name: name, unit: unit, data: data} = metric, resource, scope) do
    base = %{
      "event_message" => name,
      "description" => metric.description,
      "metric_metadata" => Otel.handle_attributes(metric.metadata),
      "unit" => unit,
      "metadata" => %{"type" => "metric"},
      "scope" => scope,
      "resource" => resource,
      "project" => Otel.resource_project(resource)
    }

    handle_metric_data(data, base)
  end

  defp handle_metric_data({:gauge, %{data_points: data_points}}, base) do
    for %{value: {_, value}} = data_point <- data_points, recorded_value?(data_point) do
      Map.merge(base, %{
        "metric_type" => "gauge",
        "flags" => data_point.flags,
        "value" => Otel.extract_value(value),
        "exemplars" => handle_exemplars(data_point.exemplars),
        "start_time" => data_point.start_time_unix_nano,
        "attributes" => Otel.handle_attributes(data_point.attributes),
        "timestamp" => data_point.time_unix_nano
      })
    end
  end

  defp handle_metric_data({:sum, sum}, base) do
    temporality = aggregation_temporality(sum.aggregation_temporality)
    is_monotonic = sum.is_monotonic

    for %{value: {_, value}} = data_point <- sum.data_points, recorded_value?(data_point) do
      Map.merge(base, %{
        "metric_type" => "sum",
        "flags" => data_point.flags,
        "aggregation_temporality" => temporality,
        "is_monotonic" => is_monotonic,
        "value" => Otel.extract_value(value),
        "exemplars" => handle_exemplars(data_point.exemplars),
        "start_time" => data_point.start_time_unix_nano,
        "attributes" => Otel.handle_attributes(data_point.attributes),
        "timestamp" => data_point.time_unix_nano
      })
    end
  end

  defp handle_metric_data({:histogram, histogram}, base) do
    temporality = aggregation_temporality(histogram.aggregation_temporality)

    for data_point <- histogram.data_points, recorded_value?(data_point) do
      Map.merge(base, %{
        "metric_type" => "histogram",
        "flags" => data_point.flags,
        "aggregation_temporality" => temporality,
        "count" => data_point.count,
        "sum" => Otel.extract_value(data_point.sum),
        "min" => Otel.extract_value(data_point.min),
        "max" => Otel.extract_value(data_point.max),
        "bucket_counts" => data_point.bucket_counts,
        "explicit_bounds" => Enum.map(data_point.explicit_bounds, &Otel.extract_value/1),
        "exemplars" => handle_exemplars(data_point.exemplars),
        "start_time" => data_point.start_time_unix_nano,
        "attributes" => Otel.handle_attributes(data_point.attributes),
        "timestamp" => data_point.time_unix_nano
      })
    end
  end

  defp handle_metric_data({:exponential_histogram, histogram}, base) do
    temporality = aggregation_temporality(histogram.aggregation_temporality)

    for data_point <- histogram.data_points, recorded_value?(data_point) do
      Map.merge(base, %{
        "metric_type" => "exponential_histogram",
        "flags" => data_point.flags,
        "aggregation_temporality" => temporality,
        "count" => data_point.count,
        "sum" => Otel.extract_value(data_point.sum),
        "scale" => data_point.scale,
        "zero_count" => data_point.zero_count,
        "zero_threshold" => Otel.extract_value(data_point.zero_threshold),
        "positive" => exponential_histogram_buckets(data_point.positive),
        "negative" => exponential_histogram_buckets(data_point.negative),
        "min" => Otel.extract_value(data_point.min),
        "max" => Otel.extract_value(data_point.max),
        "exemplars" => handle_exemplars(data_point.exemplars),
        "start_time" => data_point.start_time_unix_nano,
        "attributes" => Otel.handle_attributes(data_point.attributes),
        "timestamp" => data_point.time_unix_nano
      })
    end
  end

  defp handle_metric_data(nil, _base), do: []

  defp handle_metric_data({type, _}, _) do
    Logger.warning("Unsupported metric type #{inspect(type)}, dropping")

    []
  end

  @spec recorded_value?(%{flags: non_neg_integer()}) :: boolean()
  defp recorded_value?(%{flags: flags}), do: Bitwise.band(flags, 1) == 0

  @spec handle_exemplars([map()]) :: [map()]
  defp handle_exemplars(exemplars) do
    for %{value: {_, value}} = exemplar <- exemplars do
      %{
        "value" => Otel.extract_value(value),
        "filtered_attributes" => Otel.handle_attributes(exemplar.filtered_attributes),
        "time_unix_nano" => exemplar.time_unix_nano,
        "span_id" => Base.encode16(exemplar.span_id, case: :lower),
        "trace_id" => Base.encode16(exemplar.trace_id, case: :lower)
      }
    end
  end

  @spec exponential_histogram_buckets(map() | nil) :: map()
  defp exponential_histogram_buckets(nil), do: %{"offset" => 0, "bucket_counts" => []}

  defp exponential_histogram_buckets(%{offset: offset, bucket_counts: bucket_counts}) do
    %{"offset" => offset, "bucket_counts" => bucket_counts}
  end

  @spec aggregation_temporality(atom() | integer()) :: String.t()
  defp aggregation_temporality(temporality)
       when temporality in [:AGGREGATION_TEMPORALITY_UNSPECIFIED, 0],
       do: "unspecified"

  defp aggregation_temporality(temporality)
       when temporality in [:AGGREGATION_TEMPORALITY_DELTA, 1],
       do: "delta"

  defp aggregation_temporality(temporality)
       when temporality in [:AGGREGATION_TEMPORALITY_CUMULATIVE, 2],
       do: "cumulative"

  defp aggregation_temporality(_temporality), do: "unspecified"
end
