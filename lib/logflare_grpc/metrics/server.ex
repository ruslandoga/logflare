defmodule LogflareGrpc.Metrics.Server do
  @moduledoc """
  GRPC Server for the Logflare Metrics Service
  """

  alias Logflare.Logs.OtelMetric
  alias Logflare.Logs.OtlpResponse
  alias Logflare.Logs.Processor
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceResponse

  use GRPC.Server,
    service: Opentelemetry.Proto.Collector.Metrics.V1.MetricsService.Service,
    compressors: [GRPC.Compressor.Gzip, LogflareGrpc.IdentityCompressor],
    http_transcode: true

  def export(%ExportMetricsServiceRequest{resource_metrics: metrics}, stream) do
    source = stream.local.source

    response =
      case Processor.ingest_with_report(metrics, OtelMetric, source) do
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
          OtlpResponse.from_report(%ExportMetricsServiceResponse{}, report, source)

        _unexpected ->
          raise GRPC.RPCError, status: :internal, message: "Internal server error."
      end

    GRPC.Server.set_trailers(stream, %{"grpc-status" => "0"})
    response
  end
end
