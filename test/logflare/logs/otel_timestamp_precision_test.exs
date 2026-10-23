defmodule Logflare.Logs.OtelTimestampPrecisionTest do
  use ExUnit.Case, async: true

  import Logflare.Factory

  alias Logflare.LogEvent
  alias Logflare.Logs.OtelLog
  alias Logflare.Logs.OtelMetric
  alias Logflare.Logs.OtelTrace
  alias Logflare.Mapper
  alias Logflare.Mapper.OtelDefaults
  alias Logflare.Mapper.OutputContext
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
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
  alias Opentelemetry.Proto.Trace.V1.Span.Event

  @nanoseconds [
    1,
    999,
    1_000,
    1_234_567_890_123,
    999_999_999_999_999_123,
    1_700_000_000_000_000_123,
    10_000_000_000_000_000_123,
    18_446_744_073_709_551_615
  ]
  @max_datetime64 9_223_372_036_854_775_807

  test "stores every OTLP signal and standalone span event in microseconds without digit guessing" do
    source = build(:source, validate_schema: false)

    for nanos <- @nanoseconds, params <- converted_events(nanos) do
      assert params["timestamp"] == nanos
      assert params["time_unix_nano"] == nanos

      event = LogEvent.make(params, %{source: source})

      assert event.valid
      refute event.timestamp_inferred
      assert event.body["timestamp"] == div(nanos, 1_000)
      assert event.body["time_unix_nano"] == nanos
    end
  end

  test "retains nanoseconds for ClickHouse and intentionally narrows NDJSON to microseconds" do
    source = build(:source, validate_schema: false)

    compiled =
      for type <- [:log, :metric, :trace], format <- [:map, :ch_row_binary, :ndjson], into: %{} do
        {{type, format}, Mapper.compile!(OtelDefaults.for_type(type, format))}
      end

    for nanos <- @nanoseconds, params <- converted_events(nanos) do
      event = LogEvent.make(params, %{source: source})
      type = event.event_type
      stored_nanos = min(nanos, @max_datetime64)

      assert Mapper.map(event.body, compiled[{type, :map}])["timestamp"] == stored_nanos

      row =
        Mapper.map(event.body, compiled[{type, :ch_row_binary}],
          output_context: OutputContext.ch_row_binary(event, <<0::128>>)
        )

      assert binary_part(row, byte_size(row) - 8, 8) == <<stored_nanos::little-signed-64>>

      json =
        Mapper.map(event.body, compiled[{type, :ndjson}],
          output_context: OutputContext.ndjson(event, OtelDefaults.config_id(type))
        )

      assert Jason.decode!(json)["timestamp"] == div(nanos, 1_000)
    end
  end

  test "preserves raw metric and trace endpoint nanoseconds" do
    for nanos <- @nanoseconds do
      [_log, metric, trace, _span_event] = converted_events(nanos)

      assert metric["start_time_unix_nano"] == nanos
      assert trace["start_time_unix_nano"] == nanos
      assert trace["end_time_unix_nano"] == nanos

      metric_map = Mapper.compile!(OtelDefaults.for_type(:metric, :map))
      trace_map = Mapper.compile!(OtelDefaults.for_type(:trace, :map))

      assert Mapper.map(metric, metric_map)["start_time_unix"] == min(nanos, @max_datetime64)
      assert Mapper.map(trace, trace_map)["start_time"] == min(nanos, @max_datetime64)
      assert Mapper.map(trace, trace_map)["end_time"] == min(nanos, @max_datetime64)
    end
  end

  test "applies explicit nanosecond units to nested event and exemplar timestamp arrays" do
    for {type, root, field} <- [
          {:trace, "events", "events.timestamp"},
          {:metric, "exemplars", "exemplars.time_unix"}
        ],
        format <- [:map, :ndjson] do
      config = OtelDefaults.for_type(type, format)
      mapping = Mapper.compile!(%{config | output: nil})
      body = %{root => Enum.map(@nanoseconds, &%{"time_unix_nano" => &1})}

      expected =
        Enum.map(@nanoseconds, fn nanos ->
          if format == :ndjson, do: div(nanos, 1_000), else: min(nanos, @max_datetime64)
        end)

      assert Mapper.map(body, mapping)[field] == expected
    end
  end

  test "uses supplied observed log time when event time is missing" do
    source = build(:source, validate_schema: false)

    for nanos <- @nanoseconds do
      params = hd(converted_events(0, nanos))
      event = LogEvent.make(params, %{source: source})

      refute event.timestamp_inferred
      assert event.body["timestamp"] == div(nanos, 1_000)
      assert event.body["observed_time_unix_nano"] == nanos

      mapping = Mapper.compile!(OtelDefaults.for_type(:log, :map))
      assert Mapper.map(event.body, mapping)["timestamp"] == min(nanos, @max_datetime64)
    end
  end

  test "infers ingestion time when OTLP times are zero and avoids mapping them back to epoch" do
    source = build(:source, validate_schema: false)
    before = System.system_time(:microsecond)

    for params <- converted_events(0) do
      event = LogEvent.make(params, %{source: source})

      assert event.timestamp_inferred
      assert event.body["timestamp"] >= before
      assert event.body["timestamp"] <= System.system_time(:microsecond)
      refute Map.has_key?(event.body, "time_unix_nano")

      mapping = Mapper.compile!(OtelDefaults.for_type(event.event_type, :map))
      assert Mapper.map(event.body, mapping)["timestamp"] == event.body["timestamp"] * 1_000
    end
  end

  test "keeps generic JSON timestamp interpretation independent of metadata type" do
    source = build(:source, validate_schema: false)

    for type <- ["span", "metric", "event", "otel_log"] do
      params = %{
        "event_message" => "generic JSON",
        "timestamp" => 999_999_999_999_999_123,
        "metadata" => %{"type" => type}
      }

      event = LogEvent.make(params, %{source: source})

      refute event.timestamp_inferred
      assert event.body["timestamp"] == params["timestamp"]
    end
  end

  @spec converted_events(non_neg_integer(), non_neg_integer()) :: [map()]
  defp converted_events(nanos, observed_nanos \\ 0) do
    resource = %Resource{}
    scope = %InstrumentationScope{}

    logs = [
      %ResourceLogs{
        resource: resource,
        scope_logs: [
          %ScopeLogs{
            scope: scope,
            log_records: [
              %LogRecord{
                body: %AnyValue{value: {:string_value, "log"}},
                time_unix_nano: nanos,
                observed_time_unix_nano: observed_nanos
              }
            ]
          }
        ]
      }
    ]

    metrics = [
      %ResourceMetrics{
        resource: resource,
        scope_metrics: [
          %ScopeMetrics{
            scope: scope,
            metrics: [
              %Metric{
                name: "gauge",
                data:
                  {:gauge,
                   %Gauge{
                     data_points: [
                       %NumberDataPoint{
                         value: {:as_int, 1},
                         time_unix_nano: nanos,
                         start_time_unix_nano: nanos
                       }
                     ]
                   }}
              }
            ]
          }
        ]
      }
    ]

    spans = [
      %ResourceSpans{
        resource: resource,
        scope_spans: [
          %ScopeSpans{
            scope: scope,
            spans: [
              %Span{
                name: "span",
                start_time_unix_nano: nanos,
                end_time_unix_nano: nanos,
                events: [%Event{name: "event", time_unix_nano: nanos}]
              }
            ]
          }
        ]
      }
    ]

    OtelLog.handle_batch(logs, nil) ++
      OtelMetric.handle_batch(metrics, nil) ++ OtelTrace.handle_batch(spans, nil)
  end
end
