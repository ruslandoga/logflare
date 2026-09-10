read = fn label, suffix ->
  Path.join("dialyzer-probe-results", label <> suffix)
  |> File.read!()
  |> :erlang.binary_to_term()
end

baseline = "baseline-incremental"
fixed = "fixed-error-incremental"
baseline_raw = read.(baseline, ".raw.etf") |> Enum.sort()
fixed_raw = read.(fixed, ".raw.etf") |> Enum.sort()
fixed_inputs = read.(fixed, ".inputs.etf")

strip_marker = fn files ->
  Enum.reject(files, &(Path.basename(to_string(&1)) == "Elixir.Logflare.CIProbe.TypeError.beam"))
end

fixed_inputs_without_marker =
  fixed_inputs
  |> Map.update!(:files, strip_marker)
  |> Map.update!(:project_files, strip_marker)

true = baseline_raw == fixed_raw
true = read.(baseline, ".filtered.etf") == read.(fixed, ".filtered.etf")
true = read.(baseline, ".inputs.etf") == fixed_inputs_without_marker
true = length(fixed_inputs.project_files) == length(fixed_inputs_without_marker.project_files) + 1
%{status: :ok, exit_status: 0} = read.(fixed, ".summary.etf")

IO.puts(
  "FIX CHECK: all baseline raw/filtered warnings preserved; only the fixed probe module is added"
)
