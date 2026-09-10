defmodule LogflareWeb.SearchLiveTestGuard do
  use GenServer

  alias Ecto.Adapters.SQL.Sandbox
  alias Logflare.Logs.LogEvents
  alias Logflare.Logs.SearchQueryExecutor
  alias Logflare.Repo
  alias Logflare.Utils.Tasks

  @mock_modules [
    ConfigCat,
    GoogleApi.BigQuery.V2.Api.Jobs,
    Goth,
    Logflare.Cluster.Utils,
    Logflare.ContextCache,
    Tasks
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec setup(map()) :: :ok
  def setup(_context) do
    owner = self()
    guard = ExUnit.Callbacks.start_supervised!(__MODULE__)
    task_supervisor = ExUnit.Callbacks.start_supervised!(Task.Supervisor)

    Mimic.stub(SearchQueryExecutor, :start_link, fn args ->
      {:ok, executor} = Mimic.call_original(SearchQueryExecutor, :start_link, [args])
      :ok = Sandbox.allow(Repo, owner, executor)
      Enum.each(@mock_modules, &Mimic.allow(&1, owner, executor))
      :ok = GenServer.call(guard, {:executor, executor, Keyword.fetch!(args, :source).token})
      {:ok, executor}
    end)

    Mimic.stub(Tasks, :async, fn fun ->
      Task.Supervisor.async(task_supervisor, fun)
    end)

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:phoenix, :live_view, :render, :stop],
        &__MODULE__.forward_render/4,
        owner
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  @spec forward_render([atom()], map(), map(), pid()) :: :ok
  def forward_render(_event, _measurements, metadata, owner) do
    if self() == owner or owner in Process.get(:"$callers", []) do
      send(owner, {:wait_for_render, metadata.socket.assigns})
    end

    :ok
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{executors: MapSet.new(), source_tokens: MapSet.new()}}
  end

  @impl true
  def handle_call({:executor, executor, token}, _from, state) do
    {:reply, :ok,
     %{
       state
       | executors: MapSet.put(state.executors, executor),
         source_tokens: MapSet.put(state.source_tokens, token)
     }}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.executors, &stop_executor/1)

    LogEvents.Cache
    |> Cachex.stream!(Cachex.Query.build(output: :key))
    |> Enum.each(fn
      {source_token, _id} = key ->
        if MapSet.member?(state.source_tokens, source_token) do
          Cachex.del!(LogEvents.Cache, key)
        end

      _key ->
        :ok
    end)

    :ok
  end

  @spec stop_executor(pid()) :: :ok
  defp stop_executor(pid) do
    if Process.alive?(pid) do
      try do
        SearchQueryExecutor.cancel_query(pid)
        SearchQueryExecutor.cancel_agg(pid)
        GenServer.stop(pid)
      catch
        :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :ok
        :exit, {{:shutdown, _reason}, _call} -> :ok
      end
    end

    :ok
  end
end
