defmodule LogflareWeb.ProtobufParserBodyReaderTest do
  use ExUnit.Case, async: true

  alias LogflareWeb.ProtobufParser
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Opentelemetry.Proto.Logs.V1.ResourceLogs

  test "forwards parser options before the configured reader's additional arguments" do
    reader_opts = [length: 12_000_000, read_length: 1_024, read_timeout: 500]

    parser_opts =
      ProtobufParser.init([body_reader: {__MODULE__, :read_body, [self()]}] ++ reader_opts)

    for {subtype, body} <- [
          {"x-protobuf", <<10, 0>>},
          {"json", ~s({"resourceLogs":[{}]})}
        ] do
      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.assign(:protobuf_schema, ExportLogsServiceRequest)
        |> Plug.Conn.put_private(:test_body, body)

      assert {:ok, %ExportLogsServiceRequest{resource_logs: [%ResourceLogs{}]}, ^conn} =
               ProtobufParser.parse(conn, "application", subtype, [], parser_opts)

      assert_receive {:reader_opts, ^reader_opts}
    end
  end

  test "the default Plug body reader still decodes non-empty protobuf requests" do
    conn =
      Plug.Test.conn(:post, "/", <<10, 0>>)
      |> Plug.Conn.assign(:protobuf_schema, ExportLogsServiceRequest)

    assert {:ok, %ExportLogsServiceRequest{resource_logs: [%ResourceLogs{}]}, _conn} =
             ProtobufParser.parse(conn, "application", "x-protobuf", [], ProtobufParser.init([]))
  end

  @spec read_body(Plug.Conn.t(), keyword(), pid()) :: {:ok, binary(), Plug.Conn.t()}
  def read_body(conn, opts, receiver) do
    send(receiver, {:reader_opts, opts})
    {:ok, conn.private.test_body, conn}
  end
end
