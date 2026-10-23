defmodule Logflare.Logs.OtlpResponse do
  @moduledoc false

  require Logger

  alias Logflare.Logs.Processor
  alias Logflare.Sources.Source
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsPartialSuccess
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceResponse
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsPartialSuccess
  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceResponse
  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTracePartialSuccess
  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceResponse

  @spec from_report(struct(), Processor.ingest_report(), Source.t()) :: struct()
  def from_report(response, %{rejected: 0}, _source), do: response

  def from_report(response, %{rejected: rejected, errors: errors}, source) do
    errors = errors |> Enum.uniq() |> Enum.take(3)

    Logger.warning("OTLP ingest rejected #{rejected} input unit(s) at validation",
      source_token: source.token,
      source_id: source.id,
      sample_errors: errors
    )

    {partial_module, count_field} = partial_success_type(response)

    partial_success =
      struct!(partial_module, [
        {count_field, rejected},
        {:error_message, Enum.join(errors, "; ")}
      ])

    %{response | partial_success: partial_success}
  end

  @spec partial_success_type(struct()) :: {module(), atom()}
  defp partial_success_type(%ExportLogsServiceResponse{}),
    do: {ExportLogsPartialSuccess, :rejected_log_records}

  defp partial_success_type(%ExportMetricsServiceResponse{}),
    do: {ExportMetricsPartialSuccess, :rejected_data_points}

  defp partial_success_type(%ExportTraceServiceResponse{}),
    do: {ExportTracePartialSuccess, :rejected_spans}
end
