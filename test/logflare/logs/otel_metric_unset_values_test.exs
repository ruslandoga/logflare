defmodule Logflare.Logs.OtelMetricUnsetValuesTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelMetric
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ResourceMetrics
  alias Opentelemetry.Proto.Metrics.V1.ScopeMetrics
  alias Opentelemetry.Proto.Metrics.V1.Sum
  alias Opentelemetry.Proto.Resource.V1.Resource

  test "drops unset metric data and number values without losing valid siblings" do
    points = [
      %NumberDataPoint{},
      %NumberDataPoint{value: {:as_int, 0}},
      %NumberDataPoint{value: {:as_double, 0.0}}
    ]

    resource_metrics = %ResourceMetrics{
      resource: %Resource{},
      scope_metrics: [
        %ScopeMetrics{
          scope: %InstrumentationScope{},
          metrics: [
            %Metric{name: "unset"},
            %Metric{name: "gauge", data: {:gauge, %Gauge{data_points: points}}},
            %Metric{name: "sum", data: {:sum, %Sum{data_points: points}}}
          ]
        }
      ]
    }

    events = OtelMetric.handle_batch([resource_metrics], nil)

    assert Enum.map(events, &{&1["event_message"], &1["value"]}) ===
             [{"gauge", 0}, {"gauge", 0.0}, {"sum", 0}, {"sum", 0.0}]
  end
end
