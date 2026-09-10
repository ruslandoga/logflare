defmodule DialyzerProbeRunner do
  @moduledoc false

  @spec run(keyword(), module()) :: tuple()
  def run(args, filterer) do
    {probe, args} = Keyword.split(args, [:probe_output])
    output = Keyword.fetch!(probe, :probe_output)

    try do
      {duration_us, warnings} = :timer.tc(&:dialyzer.run/1, [args])
      File.write!(output <> ".raw.etf", :erlang.term_to_binary(warnings))

      File.write!(
        output <> ".raw.txt",
        inspect(Enum.sort(warnings), limit: :infinity, pretty: true)
      )

      result =
        Dialyxir.Formatter.format_and_filter(
          warnings,
          filterer,
          Dialyxir.FilterMap.to_args([]),
          [Dialyxir.Formatter.Dialyxir],
          false
        )

      File.write!(output <> ".filtered.etf", :erlang.term_to_binary(result))

      File.write!(
        output <> ".analysis.json",
        Jason.encode!(%{
          analysis_seconds: duration_us / 1_000_000,
          raw_warnings: length(warnings)
        })
      )

      time = Dialyxir.Formatter.formatted_time(duration_us)

      case result do
        {:ok, warnings, :no_unused_filters} ->
          {:ok, {time, warnings, ""}}

        {:warn, warnings, {:unused_filters_present, unused}} ->
          {:ok, {time, warnings, unused}}

        {:error, _warnings, {:unused_filters_present, unused}} ->
          {:error, {"unused filters present", unused}}
      end
    catch
      {:dialyzer_error, message} -> {:error, ":dialyzer.run error: " <> to_string(message)}
    end
  end
end
