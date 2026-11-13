defmodule Logflare.Alerting.AlertWorkerTest do
  use Logflare.DataCase, async: false
  use Oban.Testing, repo: Logflare.Repo

  alias Logflare.Alerting
  alias Logflare.Alerting.AlertWorker

  setup do
    insert(:plan, name: "Free")
    old_config = Application.get_env(:logflare, Logflare.Alerting)
    Application.put_env(:logflare, Logflare.Alerting, min_cluster_size: 0, enabled: true)
    on_exit(fn -> Application.put_env(:logflare, Logflare.Alerting, old_config) end)
    {:ok, user: insert(:user)}
  end

  test "perform/1 executes alert and sends notifications on results", %{user: user} do
    alert = insert(:alert, user: user)

    GoogleApi.BigQuery.V2.Api.Jobs
    |> expect(:bigquery_jobs_query, 1, fn _conn, _proj_id, _opts ->
      {:ok, TestUtils.gen_bq_response([%{"testing" => "123"}])}
    end)

    Logflare.Backends.Adaptor.WebhookAdaptor.Client
    |> expect(:send, fn opts ->
      assert Map.has_key?(opts[:body], "result")
      {:ok, %Tesla.Env{}}
    end)

    Logflare.Backends.Adaptor.SlackAdaptor.Client
    |> expect(:send, fn _url, body ->
      assert Map.has_key?(body, :blocks)
      {:ok, %Tesla.Env{}}
    end)

    assert :ok = perform_job(AlertWorker, %{alert_query_id: alert.id})
  end

  test "perform/1 returns :ok when no query results", %{user: user} do
    alert = insert(:alert, user: user)

    GoogleApi.BigQuery.V2.Api.Jobs
    |> expect(:bigquery_jobs_query, 1, fn _conn, _proj_id, _opts ->
      {:ok, TestUtils.gen_bq_response([])}
    end)

    assert :ok = perform_job(AlertWorker, %{alert_query_id: alert.id})
  end

  test "perform/1 returns :error when alert not found (deleted)" do
    assert {:error, :not_found} = perform_job(AlertWorker, %{alert_query_id: -1})
  end

  test "evaluates PromQL at the job's scheduled time and persists warnings", %{user: user} do
    alert = promql_alert(user)

    expect(Tesla.Adapter.Finch, :call, fn env, _opts ->
      assert URI.decode_query(env.body)["time"] == "2026-10-19T12:04:30Z"

      response = %{
        "status" => "success",
        "data" => %{"resultType" => "vector", "result" => []},
        "warnings" => ["partial data"]
      }

      {:ok, %{env | status: 200, body: Jason.encode!(response)}}
    end)

    job =
      %{alert_query_id: alert.id, scheduled_at: "2026-10-19T12:05:00Z"}
      |> AlertWorker.new()
      |> Oban.insert!()

    assert :ok = AlertWorker.perform(Repo.reload!(job))

    assert %{"result" => %{"fired" => false, "warnings" => ["partial data"]}} =
             Repo.reload!(job).meta
  end

  test "persists upstream PromQL errors in JSONB without turning them into healthy evaluations",
       %{user: user} do
    alert = promql_alert(user)

    expect(Tesla.Adapter.Finch, :call, fn env, _opts ->
      response = %{
        "status" => "error",
        "errorType" => "bad_data",
        "error" => "invalid expression"
      }

      {:ok, %{env | status: 422, body: Jason.encode!(response)}}
    end)

    {:ok, job} = Alerting.trigger_alert_now(alert)

    assert {:error, %{"errorType" => "bad_data"} = reason} =
             AlertWorker.perform(Repo.reload!(job))

    assert %{"reason" => ^reason} = Repo.reload!(job).meta
    refute Map.has_key?(Repo.reload!(job).meta, "result")
  end

  defp promql_alert(user) do
    backend =
      insert(:backend,
        user: user,
        type: :victoria_metrics,
        config: %{url: "https://8.8.8.8/api/v1/write", query_url: "https://8.8.8.8"}
      )

    insert(:alert,
      user: user,
      language: :promql,
      query: "up == 0",
      query_backend_id: backend.id,
      slack_hook_url: nil,
      webhook_notification_url: nil
    )
  end
end
