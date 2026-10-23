defmodule LogflareGrpc.Logs.Server do
  @moduledoc """
  GRPC Server for the Logflare Otel Logs Service
  """

  alias Logflare.Logs.OtelLog
  alias Logflare.Logs.OtlpResponse
  alias Logflare.Logs.Processor
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceResponse

  use GRPC.Server,
    service: Opentelemetry.Proto.Collector.Logs.V1.LogsService.Service,
    compressors: [GRPC.Compressor.Gzip, LogflareGrpc.IdentityCompressor],
    http_transcode: true

  def export(%ExportLogsServiceRequest{resource_logs: logs}, stream) do
    source = stream.local.source

    response =
      case Processor.ingest_with_report(logs, OtelLog, source) do
        {:error, :source_not_found} ->
          raise GRPC.RPCError, status: :not_found, message: "Source not found."

        {:error, :source_unavailable} ->
          raise GRPC.RPCError,
            status: :unavailable,
            message: "Source is unavailable. Send the batch again."

        {:error, :spool_unavailable} ->
          raise GRPC.RPCError,
            status: :unavailable,
            message: "Ingest spool is unavailable. Send the batch again."

        {:ok, report} ->
          OtlpResponse.from_report(%ExportLogsServiceResponse{}, report, source)

        _unexpected ->
          raise GRPC.RPCError, status: :internal, message: "Internal server error."
      end

    GRPC.Server.set_trailers(stream, %{"grpc-status" => "0"})
    response
  end
end
