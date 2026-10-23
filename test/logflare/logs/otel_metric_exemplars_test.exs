defmodule Logflare.Logs.OtelMetricExemplarsTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelMetric
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Metrics.V1.Exemplar
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogram
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ExponentialHistogramDataPoint.Buckets
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Histogram
  alias Opentelemetry.Proto.Metrics.V1.HistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Sum

  test "preserves valid exemplars for all metric types and skips unset exemplar values" do
    exemplar = %Exemplar{
      value: {:as_int, 7},
      time_unix_nano: 1_751_301_254_474_000_000,
      trace_id: <<1::128>>,
      span_id: <<2::64>>,
      filtered_attributes: [
        %KeyValue{key: "route", value: %AnyValue{value: {:string_value, "/"}}}
      ]
    }

    exemplars = [%Exemplar{}, exemplar, %Exemplar{value: {:as_double, 0.0}}]
    number = %NumberDataPoint{value: {:as_int, 1}, exemplars: exemplars}

    for data <- [
          {:gauge, %Gauge{data_points: [number]}},
          {:sum, %Sum{data_points: [number]}},
          {:histogram, %Histogram{data_points: [%HistogramDataPoint{exemplars: exemplars}]}},
          {:exponential_histogram,
           %ExponentialHistogram{
             data_points: [
               %ExponentialHistogramDataPoint{
                 exemplars: exemplars,
                 positive: %Buckets{},
                 negative: %Buckets{}
               }
             ]
           }}
        ] do
      assert [event] = OtelMetric.handle_metric(%Metric{data: data}, %{}, %{})
      assert [converted, without_ids] = event["exemplars"]

      assert converted == %{
               "value" => 7,
               "time_unix_nano" => exemplar.time_unix_nano,
               "trace_id" => "00000000000000000000000000000001",
               "span_id" => "0000000000000002",
               "filtered_attributes" => %{"route" => "/"}
             }

      assert without_ids["value"] === 0.0
      assert without_ids["trace_id"] == ""
      assert without_ids["span_id"] == ""
      assert {:ok, _} = Jason.encode(event)
    end
  end
end
