defmodule Logflare.Logs.Processor do
  @moduledoc """
  Processor definition for logs ingestion.

  This module define behaviour for processing logs from external format (one
  coming from the client) to the internal one that is used by the application
  itself.
  """

  alias Logflare.Backends
  alias Logflare.Logs.OtelTrace
  alias Logflare.Sources.Source

  @type ingest_report :: %{rejected: non_neg_integer(), errors: [String.t()]}

  @doc """
  Translate `data` into format that will be used for storage.
  """
  @callback handle_batch(data :: [map()], source :: Logflare.Sources.Source.t()) :: [map()]
  @callback handle_batch_with_report(data :: [map()], source :: Source.t()) ::
              {[map()], ingest_report()}
  @optional_callbacks handle_batch_with_report: 2

  @doc """
  Process `data` using `processor` to translate from incoming format to storage format.

  The function first makes sure that the `SourceSup` of the source is up. That wait has a time
  limit (see `Logflare.Backends.start_source_sup/1`). When the `SourceSup` is still not up after
  the wait, the function does not ingest and returns `{:error, :source_unavailable}`. The write
  is not certain then, so the caller must tell the client to send the batch again.

  When the source was deleted after the caller loaded it, the function does not ingest and
  returns `{:error, :source_not_found}`.
  """
  @spec ingest([map()], module(), Logflare.Sources.Source.t()) ::
          :ok
          | {:ok, count :: pos_integer()}
          | {:error, :source_unavailable | :source_not_found | term()}
  def ingest(data, processor, %Source{} = source)
      when is_list(data) and is_atom(processor) do
    with :ok <- Backends.start_for_ingest(source) do
      process_and_store(data, processor, source, :legacy)
    end
  end

  @doc """
  Processes OTLP data and reports rejected input records, data points, or spans.

  A span and its derived standalone event records are one input unit. If any of
  those records fails validation, the original span is counted once, even when
  multiple records fail. Repeated trace/span IDs remain distinct input spans.
  """
  @spec ingest_with_report([map()], module(), Source.t()) ::
          {:ok, ingest_report()} | {:error, term()}
  def ingest_with_report(data, processor, %Source{} = source)
      when is_list(data) and is_atom(processor) do
    with :ok <- Backends.start_for_ingest(source) do
      process_and_store(data, processor, source, :report)
    end
  end

  @spec process_and_store([map()], module(), Source.t(), :legacy | :report) ::
          {:ok, non_neg_integer() | ingest_report()} | {:error, term()}
  defp process_and_store(data, processor, source, result_format) do
    metadata = %{
      processor: processor,
      source_token: source.token,
      source_id: source.id
    }

    :telemetry.span([:logflare, :logs, :processor, :ingest], metadata, fn ->
      {batch, conversion_report} =
        :telemetry.span([:logflare, :logs, :processor, :ingest, :handle_batch], metadata, fn ->
          {convert_batch(data, processor, source, result_format), metadata}
        end)

      :telemetry.execute(
        [:logflare, :logs, :processor, :ingest, :logs],
        %{
          count: length(batch)
        },
        metadata
      )

      :telemetry.span([:logflare, :logs, :processor, :ingest, :store], metadata, fn ->
        # allow_spooling: true — this is the genuine client-submitted entry
        # point (every log_controller.ex/gRPC ingestion action funnels
        # through here), as opposed to SourceRouter's re-entrant calls,
        # which never pass this and so can never be spooled.
        result = store_batch(batch, processor, source, result_format, conversion_report)

        new_meta = Map.merge(metadata, %{success: match?({:ok, _}, result)})

        {{result, new_meta}, new_meta}
      end)
    end)
  end

  @spec convert_batch([map()], module(), Source.t(), :legacy | :report) ::
          {[map()], ingest_report()}
  defp convert_batch(data, processor, source, :legacy),
    do: {processor.handle_batch(data, source), %{rejected: 0, errors: []}}

  defp convert_batch(data, processor, source, :report) do
    Code.ensure_loaded!(processor)

    if function_exported?(processor, :handle_batch_with_report, 2),
      do: processor.handle_batch_with_report(data, source),
      else: convert_batch(data, processor, source, :legacy)
  end

  @spec store_batch([map()], module(), Source.t(), :legacy | :report, ingest_report()) ::
          {:ok, non_neg_integer() | ingest_report()} | {:error, term()}
  defp store_batch(batch, _processor, source, :legacy, _conversion_report),
    do: Backends.ingest_logs(batch, source, nil, true)

  defp store_batch(batch, processor, source, :report, conversion_report) do
    with {:ok, %{rejections: rejections}} <-
           Backends.ingest_logs_with_rejections(batch, source, nil, true) do
      {:ok,
       %{
         rejected: conversion_report.rejected + rejected_units(batch, processor, rejections),
         errors:
           conversion_report.errors ++ Enum.map(rejections, fn {_index, message} -> message end)
       }}
    end
  end

  @spec rejected_units([map()], module(), [{non_neg_integer(), String.t()}]) :: non_neg_integer()
  defp rejected_units(batch, OtelTrace, rejections) do
    rejected_indices = MapSet.new(rejections, fn {index, _message} -> index end)

    {rejected_spans, _span_index} =
      batch
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), -1}, fn {event, index}, {rejected_spans, span_index} ->
        span_index =
          if get_in(event, ["metadata", "type"]) == "span", do: span_index + 1, else: span_index

        rejected_spans =
          if MapSet.member?(rejected_indices, index),
            do: MapSet.put(rejected_spans, span_index),
            else: rejected_spans

        {rejected_spans, span_index}
      end)

    MapSet.size(rejected_spans)
  end

  defp rejected_units(_batch, _processor, rejections), do: length(rejections)
end
