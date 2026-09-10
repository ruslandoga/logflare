Code.require_file("dialyzer_probe_runner.exs", __DIR__)

[mode, label] = System.argv()
{:ok, version} = Application.ensure_all_started(:dialyxir)
_ = version
unless Application.spec(:dialyxir, :vsn) == ~c"1.4.7", do: raise("Probe requires Dialyxir 1.4.7")

started = System.monotonic_time(:microsecond)
File.mkdir_p!("dialyzer-probe-results")
File.mkdir_p!("dialyzer-incremental")
output = Path.join("dialyzer-probe-results", label)
project_files = Dialyxir.Project.dialyzer_files() |> Enum.sort()
plt = Dialyxir.Project.plt_file() |> String.to_charlist()
{:ok, info} = :dialyzer.plt_info(plt)
plt_files = Keyword.fetch!(info, :files)

files =
  (Enum.filter(plt_files, &File.regular?/1) ++ project_files)
  |> Map.new(fn file -> {Path.basename(to_string(file)), file} end)
  |> Map.values()
  |> Enum.sort()

flags =
  Enum.map(Dialyxir.Project.dialyzer_flags(), fn
    flag when is_atom(flag) ->
      flag

    flag when is_binary(flag) ->
      flag |> String.replace_leading("-W", "") |> String.replace("--", "") |> String.to_atom()
  end) ++ ([:unknown] -- Dialyxir.Project.dialyzer_removed_defaults())

args =
  case mode do
    "classic" ->
      [check_plt: false, init_plt: plt, files: project_files]

    "incremental" ->
      iplt = ~c"dialyzer-incremental/logflare.iplt"

      [
        analysis_type: :incremental,
        init_plt: iplt,
        output_plt: iplt,
        files: files,
        warning_files: project_files,
        metrics_file: String.to_charlist(output <> ".metrics.txt")
      ]
  end

File.write!(
  output <> ".inputs.etf",
  :erlang.term_to_binary(%{files: files, project_files: project_files, warnings: flags})
)

IO.puts(
  "PROBE #{label}: #{length(project_files)} warning modules / #{length(files)} total modules"
)

{status, exit_status, report} =
  Dialyxir.Dialyzer.dialyze(args ++ [warnings: flags, probe_output: output], DialyzerProbeRunner)

Enum.each(report, &IO.puts/1)

summary = %{
  label: label,
  mode: mode,
  status: status,
  exit_status: exit_status,
  wrapper_seconds: (System.monotonic_time(:microsecond) - started) / 1_000_000,
  project_files: length(project_files),
  total_files: length(files)
}

File.write!(output <> ".summary.json", Jason.encode!(summary, pretty: true))
IO.puts("PROBE_RESULT " <> Jason.encode!(summary))
System.halt(exit_status)
