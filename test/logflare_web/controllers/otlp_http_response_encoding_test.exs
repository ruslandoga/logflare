defmodule LogflareWeb.OtlpHttpResponseEncodingTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Logflare.Backends
  alias Logflare.Sources.Source
  alias LogflareWeb.LogController
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceResponse
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceResponse
  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceRequest
  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceResponse

  setup :verify_on_exit!

  setup do
    stub(Backends, :start_for_ingest, fn _source -> :ok end)

    stub(Backends, :ingest_logs_with_rejections, fn [], _source, nil, true ->
      {:ok, %{accepted: 0, rejections: []}}
    end)

    :ok
  end

  test "each OTLP signal returns JSON for JSON requests, including content-type parameters" do
    for {action, request, response} <- signals() do
      conn = request_conn("application/json; charset=utf-8")
      conn = apply(LogController, action, [conn, struct(request)])

      assert conn.status == 200
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/json")
      assert Protobuf.JSON.decode!(conn.resp_body, response) == struct(response)
    end
  end

  test "each OTLP signal retains binary protobuf success responses" do
    for {action, request, response} <- signals() do
      conn = request_conn("application/x-protobuf")
      conn = apply(LogController, action, [conn, struct(request)])

      assert conn.status == 200
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/x-protobuf")
      assert Protobuf.decode(conn.resp_body, response) == struct(response)
    end
  end

  test "JSON error responses use the Google RPC Status JSON schema" do
    stub(Backends, :start_for_ingest, fn _source -> {:error, :source_not_found} end)

    conn =
      "application/json"
      |> request_conn()
      |> LogController.otel_logs(%ExportLogsServiceRequest{})

    assert conn.status == 404
    assert conn.halted
    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/json")

    assert %Google.Rpc.Status{message: "Source not found."} =
             Protobuf.JSON.decode!(conn.resp_body, Google.Rpc.Status)
  end

  test "binary error responses declare their protobuf content type" do
    stub(Backends, :start_for_ingest, fn _source -> {:error, :source_not_found} end)

    conn =
      "application/x-protobuf"
      |> request_conn()
      |> LogController.otel_logs(%ExportLogsServiceRequest{})

    assert conn.status == 404
    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/x-protobuf")

    assert %Google.Rpc.Status{message: "Source not found."} =
             Protobuf.decode(conn.resp_body, Google.Rpc.Status)
  end

  @spec signals() :: [{atom(), module(), module()}]
  defp signals do
    [
      {:otel_logs, ExportLogsServiceRequest, ExportLogsServiceResponse},
      {:otel_metrics, ExportMetricsServiceRequest, ExportMetricsServiceResponse},
      {:otel_traces, ExportTraceServiceRequest, ExportTraceServiceResponse}
    ]
  end

  @spec request_conn(binary()) :: Plug.Conn.t()
  defp request_conn(content_type) do
    Plug.Test.conn(:post, "/")
    |> Plug.Conn.put_req_header("content-type", content_type)
    |> Plug.Conn.assign(:source, %Source{id: 1, token: :otlp_response_encoding_test})
  end
end
