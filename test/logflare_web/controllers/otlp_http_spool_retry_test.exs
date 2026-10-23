defmodule LogflareWeb.OtlpHttpSpoolRetryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Logflare.Backends
  alias Logflare.Sources.Source
  alias LogflareWeb.LogController
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceRequest

  setup :verify_on_exit!

  test "each OTLP signal reports a retryable failure when the spool is unavailable" do
    stub(Backends, :start_for_ingest, fn _source -> :ok end)
    stub(Backends, :ingest_logs, fn [], _source, nil, true -> {:error, :spool_unavailable} end)

    for {action, request} <- [
          {:otel_logs, ExportLogsServiceRequest},
          {:otel_metrics, ExportMetricsServiceRequest},
          {:otel_traces, ExportTraceServiceRequest}
        ] do
      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("content-type", "application/x-protobuf")
        |> Plug.Conn.assign(:source, %Source{id: 1, token: :otlp_spool_retry_test})

      conn = apply(LogController, action, [conn, struct(request)])

      assert conn.status == 503
      assert conn.halted
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["5"]

      assert %Google.Rpc.Status{
               message: "Ingestion spool is unavailable. Send the batch again."
             } = Protobuf.decode(conn.resp_body, Google.Rpc.Status)
    end
  end
end
