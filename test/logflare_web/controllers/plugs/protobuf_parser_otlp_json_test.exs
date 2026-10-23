defmodule LogflareWeb.ProtobufParserOtlpJsonTest do
  use ExUnit.Case, async: true

  alias LogflareWeb.ProtobufParser
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceRequest

  @trace_id "00112233445566778899aAbBcCdDeEfF"
  @span_id "aAbBcCdDeEfF0011"

  test "decodes log identifiers as hex while preserving attribute values and AnyValue bytes" do
    bytes = <<0, 255, 128>>

    [record] =
      %{
        "traceId" => @trace_id,
        "spanId" => @span_id,
        "body" => %{"bytesValue" => Base.encode64(bytes)},
        "attributes" => [
          %{"key" => "traceId", "value" => %{"stringValue" => @trace_id}},
          %{"key" => "spanId", "value" => %{"bytesValue" => Base.encode64(bytes)}}
        ]
      }
      |> logs_payload()
      |> decode_json(ExportLogsServiceRequest)
      |> log_records()

    assert record.trace_id == Base.decode16!(@trace_id, case: :mixed)
    assert record.span_id == Base.decode16!(@span_id, case: :mixed)
    assert record.body.value == {:bytes_value, bytes}

    assert Enum.map(record.attributes, & &1.value.value) ==
             [{:string_value, @trace_id}, {:bytes_value, bytes}]
  end

  test "decodes span, parent, and link identifiers" do
    payload = %{
      "resourceSpans" => [
        %{
          "scopeSpans" => [
            %{
              "spans" => [
                %{
                  "traceId" => @trace_id,
                  "spanId" => @span_id,
                  "parentSpanId" => "1020304050607080",
                  "links" => [%{"traceId" => @trace_id, "spanId" => @span_id}]
                }
              ]
            }
          ]
        }
      ]
    }

    request = decode_json(payload, ExportTraceServiceRequest)
    [%{scope_spans: [%{spans: [span]}]}] = request.resource_spans
    [link] = span.links

    assert span.trace_id == link.trace_id
    assert span.trace_id == Base.decode16!(@trace_id, case: :mixed)
    assert span.span_id == link.span_id
    assert span.span_id == Base.decode16!(@span_id, case: :mixed)
    assert span.parent_span_id == Base.decode16!("1020304050607080")
  end

  test "decodes metric exemplar identifiers" do
    payload = %{
      "resourceMetrics" => [
        %{
          "scopeMetrics" => [
            %{
              "metrics" => [
                %{
                  "gauge" => %{
                    "dataPoints" => [
                      %{
                        "asDouble" => 1,
                        "exemplars" => [
                          %{"asDouble" => 1, "traceId" => @trace_id, "spanId" => @span_id}
                        ]
                      }
                    ]
                  }
                }
              ]
            }
          ]
        }
      ]
    }

    request = decode_json(payload, ExportMetricsServiceRequest)
    [%{scope_metrics: [%{metrics: [%{data: {:gauge, gauge}}]}]}] = request.resource_metrics
    [%{exemplars: [exemplar]}] = gauge.data_points

    assert exemplar.trace_id == Base.decode16!(@trace_id, case: :mixed)
    assert exemplar.span_id == Base.decode16!(@span_id, case: :mixed)
  end

  test "rejects malformed non-empty identifiers as parse errors" do
    for record <- [
          %{"traceId" => String.duplicate("g", 32)},
          %{"traceId" => String.duplicate("0", 30)},
          %{"spanId" => String.duplicate("0", 14)}
        ] do
      assert_raise Plug.Parsers.ParseError, fn ->
        record |> logs_payload() |> decode_json(ExportLogsServiceRequest)
      end
    end
  end

  test "accepts omitted and empty optional identifiers" do
    for record <- [%{}, %{"traceId" => "", "spanId" => ""}] do
      assert [%{trace_id: "", span_id: ""}] =
               record
               |> logs_payload()
               |> decode_json(ExportLogsServiceRequest)
               |> log_records()
    end
  end

  test "preserves the binary protobuf decoding path" do
    request =
      %{"traceId" => @trace_id, "spanId" => @span_id}
      |> logs_payload()
      |> decode_json(ExportLogsServiceRequest)

    conn =
      Plug.Test.conn(:post, "/")
      |> Plug.Conn.assign(:protobuf_schema, ExportLogsServiceRequest)

    assert {:ok, ^request, ^conn} =
             ProtobufParser.decode({:ok, Protobuf.encode(request), conn}, :protobuf)
  end

  @spec logs_payload(map()) :: map()
  defp logs_payload(record) do
    %{"resourceLogs" => [%{"scopeLogs" => [%{"logRecords" => [record]}]}]}
  end

  @spec log_records(ExportLogsServiceRequest.t()) :: [map()]
  defp log_records(%{resource_logs: [%{scope_logs: [%{log_records: records}]}]}), do: records

  @spec decode_json(map(), module()) :: struct()
  defp decode_json(payload, schema) do
    conn = Plug.Test.conn(:post, "/") |> Plug.Conn.assign(:protobuf_schema, schema)
    {:ok, request, _conn} = ProtobufParser.decode({:ok, Jason.encode!(payload), conn}, :json)
    request
  end
end
