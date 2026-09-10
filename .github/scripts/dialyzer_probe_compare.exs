[left, right] = System.argv()

read = fn label, suffix ->
  Path.join("dialyzer-probe-results", label <> suffix) |> File.read!() |> :erlang.binary_to_term()
end

left_raw = read.(left, ".raw.etf") |> Enum.sort()
right_raw = read.(right, ".raw.etf") |> Enum.sort()
normalize_filtered = fn {status, warnings, unused} -> {status, Enum.sort(warnings), unused} end
left_filtered = read.(left, ".filtered.etf") |> normalize_filtered.()
right_filtered = read.(right, ".filtered.etf") |> normalize_filtered.()
same_raw = left_raw == right_raw
same_filtered = left_filtered == right_filtered
same_inputs = read.(left, ".inputs.etf") == read.(right, ".inputs.etf")

same_status =
  Map.take(read.(left, ".summary.etf"), [:status, :exit_status]) ==
    Map.take(read.(right, ".summary.etf"), [:status, :exit_status])

IO.puts(
  "PARITY #{left} vs #{right}: raw=#{same_raw}, filtered=#{same_filtered}, inputs=#{same_inputs}, status=#{same_status}"
)

unless same_raw and same_filtered and same_inputs and same_status do
  IO.inspect(left_raw -- right_raw, label: "Only in #{left}", limit: :infinity)
  IO.inspect(right_raw -- left_raw, label: "Only in #{right}", limit: :infinity)
  System.halt(1)
end
