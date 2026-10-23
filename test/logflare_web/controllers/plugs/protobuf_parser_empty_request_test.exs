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

  test "empty JSON bodies retain the existing empty params policy" do
    conn = Plug.Test.conn(:post, "/")

    assert {:ok, %{}, ^conn} = ProtobufParser.decode({:ok, <<>>, conn}, :json)
  end
end
