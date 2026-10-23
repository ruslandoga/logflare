defmodule LogflareWeb.OtlpHttpUnexpectedResultTest do
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
    :ok
  end

  test "unexpected ingest results fail without acknowledging the batch" do
    for content_type <- ["application/json", "application/x-protobuf"],
        {action, request, _response} <- signals(),
        result <- [{:error, :unexpected}, :unexpected, {:error, ["legacy validation error"]}] do
      stub(Backends, :ingest_logs_with_rejections, fn [], _source, nil, true -> result end)
      conn = apply(LogController, action, [request_conn(content_type), struct(request)])

      assert conn.status == 500
      assert conn.halted
      assert [response_content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert String.starts_with?(response_content_type, content_type)

      assert %Google.Rpc.Status{message: "Internal server error"} =
               decode_response(conn.resp_body, content_type, Google.Rpc.Status)
    end
  end

  test "a valid empty ingest report retains a normal full-success response" do
    stub(Backends, :ingest_logs_with_rejections, fn [], _source, nil, true ->
      {:ok, %{accepted: 0, rejections: []}}
    end)

    for content_type <- ["application/json", "application/x-protobuf"],
        {action, request, response} <- signals() do
      conn = apply(LogController, action, [request_conn(content_type), struct(request)])

      assert conn.status == 200
      refute conn.halted
      assert [response_content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert String.starts_with?(response_content_type, content_type)
      assert decode_response(conn.resp_body, content_type, response) == struct(response)
    end
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
    |> Plug.Conn.assign(:source, %Source{id: 1, token: :otlp_http_unexpected_result_test})
  end

  @spec decode_response(binary(), binary(), module()) :: struct()
  defp decode_response(body, "application/json", schema), do: Protobuf.JSON.decode!(body, schema)
  defp decode_response(body, "application/x-protobuf", schema), do: Protobuf.decode(body, schema)
end
