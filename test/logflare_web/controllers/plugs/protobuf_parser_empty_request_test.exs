defmodule LogflareWeb.ProtobufParserEmptyRequestTest do
  use ExUnit.Case, async: true

  alias LogflareWeb.ProtobufParser
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceRequest

  test "empty binary protobuf bodies decode to the assigned request schema" do
    for schema <- [
          ExportLogsServiceRequest,
          ExportMetricsServiceRequest,
          ExportTraceServiceRequest
        ] do
      conn = Plug.Test.conn(:post, "/") |> Plug.Conn.assign(:protobuf_schema, schema)

      assert {:ok, request, ^conn} = ProtobufParser.decode({:ok, <<>>, conn}, :protobuf)
      assert request == struct(schema)
    end
  end

  test "empty JSON bodies are rejected as malformed JSON for every assigned schema" do
    for schema <- [
          ExportLogsServiceRequest,
          ExportMetricsServiceRequest,
          ExportTraceServiceRequest
        ] do
      conn = Plug.Test.conn(:post, "/") |> Plug.Conn.assign(:protobuf_schema, schema)

      assert_raise Plug.Parsers.ParseError, fn ->
        ProtobufParser.decode({:ok, <<>>, conn}, :json)
      end
    end
  end

  test "an empty JSON object decodes to the assigned request schema" do
    for schema <- [
          ExportLogsServiceRequest,
          ExportMetricsServiceRequest,
          ExportTraceServiceRequest
        ] do
      conn = Plug.Test.conn(:post, "/") |> Plug.Conn.assign(:protobuf_schema, schema)

      assert {:ok, request, ^conn} = ProtobufParser.decode({:ok, "{}", conn}, :json)
      assert request == struct(schema)
    end
  end
end
