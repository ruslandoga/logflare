defmodule LogflareWeb.OtlpPipelineErrorResponseTest do
  use LogflareWeb.ConnCase

  alias Logflare.Backends
  alias Logflare.Sources.Source
  alias LogflareWeb.LogController
  alias LogflareWeb.Plugs.OtlpErrorResponse
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest

  @paths ["/v1/logs", "/v1/metrics", "/v1/traces"]
  @content_types ["application/json", "application/x-protobuf"]

  test "OTLP authentication failures use matching Google RPC Status responses" do
    for path <- @paths, content_type <- @content_types do
      conn = dispatch_request(path, content_type, "unparsed private payload")

      assert conn.status == 401
      assert_status(conn.resp_headers, conn.resp_body, content_type, 16, "Unauthorized")
      refute conn.resp_body =~ "private payload"
    end
  end

  test "malformed OTLP requests retain the error encoder through endpoint exception rendering" do
    user = insert(:user)

    for path <- @paths,
        {content_type, body} <- [{"application/json", "{"}, {"application/x-protobuf", <<255>>}] do
      {400, headers, response} =
        assert_error_sent(400, fn ->
          dispatch_request(path, content_type, body, user.api_key)
        end)

      assert_status(headers, response, content_type, 3, "Bad Request")
    end
  end

  test "oversized OTLP bodies retain the error encoder through endpoint exception rendering" do
    user = insert(:user)
    body = String.duplicate("a", 12_000_001)

    for path <- @paths, content_type <- @content_types do
      {413, headers, response} =
        assert_error_sent(413, fn ->
          dispatch_request(path, content_type, body, user.api_key)
        end)

      assert_status(headers, response, content_type, 8, Plug.Conn.Status.reason_phrase(413))
    end
  end

  test "preserves already encoded controller failures and their retry headers" do
    stub(Backends, :start_for_ingest, fn _source -> {:error, :source_unavailable} end)

    for content_type <- @content_types do
      conn =
        build_conn()
        |> put_req_header("content-type", content_type)
        |> assign(:source, %Source{id: 1, token: :otlp_pipeline_error_test})
        |> OtlpErrorResponse.call([])
        |> LogController.otel_logs(%ExportLogsServiceRequest{})

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["5"]

      assert_status(
        conn.resp_headers,
        conn.resp_body,
        content_type,
        14,
        "Source is unavailable. Send the batch again."
      )
    end
  end

  test "preserves successful bodies and non-OTLP authentication responses" do
    conn =
      build_conn()
      |> OtlpErrorResponse.call([])
      |> put_resp_content_type("text/plain")
      |> send_resp(200, "success")

    assert conn.resp_body == "success"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    conn = dispatch_request("/logs", "application/json", "{}")
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end

  test "maps HTTP failure categories to Google RPC status codes" do
    for {http_status, code} <- [
          {400, 3},
          {401, 16},
          {403, 7},
          {404, 5},
          {413, 8},
          {429, 8},
          {500, 13},
          {503, 14}
        ] do
      assert %Google.Rpc.Status{code: ^code, message: "failure"} =
               OtlpErrorResponse.status(http_status, "failure")
    end
  end

  @spec dispatch_request(binary(), binary(), binary(), binary() | nil) :: Plug.Conn.t()
  defp dispatch_request(path, content_type, body, api_key \\ nil) do
    conn = build_conn() |> put_req_header("content-type", content_type)
    conn = if api_key, do: put_req_header(conn, "x-api-key", api_key), else: conn
    Phoenix.ConnTest.dispatch(conn, @endpoint, :post, path, body)
  end

  @spec assert_status(list(), binary(), binary(), integer(), binary()) :: :ok
  defp assert_status(headers, body, content_type, code, message) do
    assert {"content-type", response_content_type} = List.keyfind(headers, "content-type", 0)
    assert String.starts_with?(response_content_type, content_type)

    status =
      case content_type do
        "application/json" -> Protobuf.JSON.decode!(body, Google.Rpc.Status)
        "application/x-protobuf" -> Protobuf.decode(body, Google.Rpc.Status)
      end

    assert %Google.Rpc.Status{code: ^code, message: ^message} = status
    :ok
  end
end
