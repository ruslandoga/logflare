[left, right] = System.argv()

read = fn label, suffix ->
  Path.join("dialyzer-probe-results", label <> suffix) |> File.read!() |> :erlang.binary_to_term()
end

left_raw = read.(left, ".raw.etf") |> Enum.sort()
right_raw = read.(right, ".raw.etf") |> Enum.sort()
left_filtered = read.(left, ".filtered.etf")
right_filtered = read.(right, ".filtered.etf")
same_raw = left_raw == right_raw
same_filtered = left_filtered == right_filtered
IO.puts("PARITY #{left} vs #{right}: raw=#{same_raw}, filtered=#{same_filtered}")

unless same_raw and same_filtered do
  IO.inspect(left_raw -- right_raw, label: "Only in #{left}", limit: :infinity)
  IO.inspect(right_raw -- left_raw, label: "Only in #{right}", limit: :infinity)
  System.halt(1)
end
