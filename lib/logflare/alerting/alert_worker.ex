defmodule Logflare.Alerting.AlertWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :alerts,
    max_attempts: 1,
    unique: [
      period: :infinity,
      keys: [:alert_query_id, :scheduled_at],
      states: [:available, :scheduled, :executing]
    ]

  import Ecto.Query

  alias Logflare.Alerting
  alias Logflare.Repo

  require Logger

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, any()}
  def perform(%Oban.Job{id: job_id, args: %{"alert_query_id" => alert_query_id} = args}) do
    opts = [evaluation_time: evaluation_time(args)]

    case Alerting.run_alert(alert_query_id, :scheduled, opts) do
      {:ok, result} ->
        meta = %{"result" => result}
        store_meta(job_id, meta)
        :ok

      {:error, reason} ->
        Logger.warning("AlertWorker failed for alert #{alert_query_id}: #{inspect(reason)}")
        store_meta(job_id, %{"reason" => reason})
        {:error, reason}
    end
  end

  defp evaluation_time(%{"scheduled_at" => scheduled_at}) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(scheduled_at)
    datetime
  end

  defp evaluation_time(_args), do: DateTime.utc_now()

  defp store_meta(job_id, meta) do
    from(j in Oban.Job, where: j.id == ^job_id)
    |> Repo.update_all(set: [meta: meta])
  end
end
