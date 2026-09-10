File.mkdir_p!("dialyzer-probe-results")
Code.ensure_loaded!(:dialyzer)
parent = self()

tracer =
  spawn(fn ->
    receive do
      {:trace, ^parent, :return_from, {:dialyzer, :run, 1}, warnings} ->
        File.write!(
          "dialyzer-probe-results/stock-classic.raw.etf",
          :erlang.term_to_binary(warnings)
        )

        send(parent, {:stock_warnings, length(warnings)})
    after
      600_000 -> send(parent, :stock_trace_timeout)
    end
  end)

1 = :erlang.trace_pattern({:dialyzer, :run, 1}, [{:_, [], [{:return_trace}]}], [:local])
1 = :erlang.trace(self(), true, [:call, {:tracer, tracer}])
Mix.Task.run("dialyzer", ["--no-compile", "--no-check"])
:erlang.trace(self(), false, [:call])
:erlang.trace_pattern({:dialyzer, :run, 1}, false, [:local])

receive do
  {:stock_warnings, count} -> IO.puts("STOCK_RAW_WARNINGS #{count}")
  :stock_trace_timeout -> raise "Stock Dialyzer trace timed out"
after
  10_000 -> raise "Stock Dialyzer trace did not deliver warnings"
end
