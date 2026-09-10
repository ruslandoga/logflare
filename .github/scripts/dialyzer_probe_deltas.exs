[classic_label, incremental_label] = System.argv()

read = fn label ->
  Path.join("dialyzer-probe-results", label <> ".raw.etf")
  |> File.read!()
  |> :erlang.binary_to_term()
end

classic_base = read.("baseline-classic")
incremental_base = read.("baseline-incremental")
classic = read.(classic_label)
incremental = read.(incremental_label)
classic_added = Enum.sort(classic -- classic_base)
incremental_added = Enum.sort(incremental -- incremental_base)
classic_removed = Enum.sort(classic_base -- classic)
incremental_removed = Enum.sort(incremental_base -- incremental)
same_delta = classic_added == incremental_added and classic_removed == incremental_removed
no_missing_classic = classic -- incremental == []

IO.inspect(
  %{
    classic_added: length(classic_added),
    incremental_added: length(incremental_added),
    classic_removed: length(classic_removed),
    incremental_removed: length(incremental_removed),
    same_delta: same_delta,
    no_missing_classic: no_missing_classic
  },
  label: "WARNING DELTAS"
)

unless same_delta and no_missing_classic, do: System.halt(1)
