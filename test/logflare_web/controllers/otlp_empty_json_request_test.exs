defmodule LogflareWeb.OtlpEmptyJsonRequestTest do
  use LogflareWeb.ConnCase

  alias Google.Rpc.Status
  alias Logflare.Backends
  alias Logflare.Sources.Source
  alias Logflare.SystemCache
  alias Logflare.User
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceResponse
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceResponse
  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceResponse

  setup do
    insert(:plan, name: "Free")
    user = insert(:user)
    source = insert(:source, user: user)

    stub(Backends, :start_for_ingest, fn _source -> :ok end)
    stub(Backends, :cached_local_pending_buffer_full?, fn _source -> false end)
    stub(SystemCache, :memory_utilization, fn -> 0.0 end)

    %{user: user, source: source}
  end

  test "empty JSON requests return a JSON INVALID_ARGUMENT status", %{user: user, source: source} do
    reject(Backends, :ingest_logs_with_rejections, 4)

    for {path, _response} <- signals() do
      {400, headers, body} =
        assert_error_sent(400, fn -> dispatch_request(path, "", user, source) end)

      assert {"content-type", content_type} = List.keyfind(headers, "content-type", 0)
      assert String.starts_with?(content_type, "application/json")

      assert %Status{code: 3, message: "Bad Request"} =
               Protobuf.JSON.decode!(body, Status)
    end
  end

  test "valid empty JSON objects remain fully accepted", %{user: user, source: source} do
    expect(Backends, :ingest_logs_with_rejections, 3, fn [], _source, nil, true ->
      {:ok, %{accepted: 0, rejections: []}}
    end)

    for {path, response} <- signals() do
      conn = dispatch_request(path, "{}", user, source)

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/json")
      assert Protobuf.JSON.decode!(conn.resp_body, response) == struct(response)
    end
  end

  @spec signals() :: [{binary(), module()}]
  defp signals do
    [
      {"/v1/logs", ExportLogsServiceResponse},
      {"/v1/metrics", ExportMetricsServiceResponse},
      {"/v1/traces", ExportTraceServiceResponse}
    ]
  end

  @spec dispatch_request(binary(), binary(), User.t(), Source.t()) :: Plug.Conn.t()
  defp dispatch_request(path, body, user, source) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-api-key", user.api_key)
      |> put_req_header("x-source", Atom.to_string(source.token))

    Phoenix.ConnTest.dispatch(conn, @endpoint, :post, path, body)
  end
end
