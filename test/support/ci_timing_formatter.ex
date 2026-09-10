defmodule Logflare.CITimingFormatter do
  use GenServer

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(opts) do
    {:ok, cli} =
      ExUnit.CLIFormatter.init(Keyword.merge(opts, trace: true, slowest: 30, slowest_modules: 20))

    {:ok,
     %{
       cli: cli,
       runner: Map.new(Keyword.take(opts, [:seed, :max_cases, :trace, :timeout])),
       origin_us: System.monotonic_time(:microsecond),
       starts: %{},
       tests: [],
       modules: []
     }}
  end

  @impl true
  @spec handle_cast(term(), map()) :: {:noreply, map()}
  def handle_cast(event, state) do
    now_us = System.monotonic_time(:microsecond) - state.origin_us
    state = record(event, state, now_us)
    {:noreply, cli} = ExUnit.CLIFormatter.handle_cast(event, state.cli)
    {:noreply, %{state | cli: cli}}
  end

  @spec record(term(), map(), integer()) :: map()
  defp record({:test_started, test}, state, now_us) do
    put_in(state.starts[{:test, test.module, test.name, test.parameters}], now_us)
  end

  defp record({:module_started, module}, state, now_us) do
    put_in(state.starts[{:module, module.name, module.parameters}], now_us)
  end

  defp record({:test_finished, test}, state, now_us) do
    key = {:test, test.module, test.name, test.parameters}
    {started_us, starts} = Map.pop(state.starts, key)

    timing = %{
      module: inspect(test.module),
      name: Atom.to_string(test.name),
      file: Path.relative_to_cwd(test.tags.file),
      line: test.tags.line,
      async: test.module.__ex_unit__(:config).async?,
      status: status(test.state),
      body_us: test.time,
      started_us: started_us,
      elapsed_us: elapsed_us(started_us, now_us)
    }

    %{state | starts: starts, tests: [timing | state.tests]}
  end

  defp record({:module_finished, module}, state, now_us) do
    {started_us, starts} = Map.pop(state.starts, {:module, module.name, module.parameters})

    failed? =
      Enum.any?(module.tests, fn test -> status(test.state) in ["failed", "invalid"] end)

    timing = %{
      module: inspect(module.name),
      file: Path.relative_to_cwd(module.file),
      line: Map.get(module.tags, :line),
      async: module.name.__ex_unit__(:config).async?,
      status: if(failed?, do: "failed", else: status(module.state)),
      test_count: length(module.tests),
      body_us: Enum.reduce(module.tests, 0, &(&1.time + &2)),
      started_us: started_us,
      elapsed_us: elapsed_us(started_us, now_us)
    }

    %{state | starts: starts, modules: [timing | state.modules]}
  end

  defp record({:suite_finished, times_us}, state, _now_us) do
    path =
      System.get_env(
        "LOGFLARE_TEST_TIMINGS_PATH",
        ".context/ci-log-noise/17-profile-timings.json"
      )

    report = %{
      runner: state.runner,
      suite_us: times_us,
      tests: Enum.reverse(state.tests),
      modules: Enum.reverse(state.modules)
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true))
    state
  end

  defp record(_event, state, _now_us), do: state

  @spec elapsed_us(integer() | nil, integer()) :: integer() | nil
  defp elapsed_us(nil, _now_us), do: nil
  defp elapsed_us(started_us, now_us), do: now_us - started_us

  @spec status(ExUnit.state()) :: String.t()
  defp status(nil), do: "passed"
  defp status({status, _details}), do: Atom.to_string(status)
end
