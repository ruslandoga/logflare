defmodule Logflare.Alerting.PromqlTest do
  use Logflare.DataCase, async: false

  alias Logflare.Alerting
  alias Logflare.Backends
  alias Logflare.Backends.Adaptor.QueryResult
  alias Logflare.Backends.Adaptor.SlackAdaptor
  alias Logflare.Backends.Adaptor.WebhookAdaptor

  @evaluation_time ~U[2026-10-19 12:05:00Z]

  setup do
    insert(:plan, name: "Free")
    user = insert(:user)
    backend = query_backend(user)

    alert =
      insert(:alert,
        user: user,
        language: :promql,
        query: "up == 0",
        query_backend_id: backend.id,
        slack_hook_url: nil,
        webhook_notification_url: nil
      )

    %{user: user, backend: backend, alert: alert}
  end

  test "creates PromQL alerts without SQL source mapping and serializes query configuration", %{
    user: user,
    backend: backend
  } do
    assert {:ok, alert} = Alerting.create_alert_query(user, attrs(backend))
    assert alert.language == :promql
    assert alert.query_backend_id == backend.id
    assert alert.evaluation_delay_seconds == 30
    assert alert.source_mapping == nil

    encoded = alert |> Alerting.preload_alert_query() |> Jason.encode!() |> Jason.decode!()
    assert encoded["query_backend_id"] == backend.id
    assert encoded["evaluation_delay_seconds"] == 30
    refute Map.has_key?(encoded, "query_backend")
  end

  test "requires an owner-accessible query-ready VictoriaMetrics backend", %{
    user: user,
    backend: backend
  } do
    other_backend = query_backend(insert(:user))
    sql_backend = insert(:backend, user: user)
    write_only = query_backend(user, %{"url" => "https://8.8.8.8/api/v1/write"})

    for backend_id <- [nil, other_backend.id, sql_backend.id, write_only.id, -1] do
      assert {:error, changeset} =
               Alerting.create_alert_query(
                 user,
                 Map.put(attrs(backend), :query_backend_id, backend_id)
               )

      assert errors_on(changeset).query_backend_id != []
    end

    assert {:error, changeset} =
             Alerting.update_alert_query(insert(:alert, user: user), attrs(other_backend))

    assert errors_on(changeset).query_backend_id != []
  end

  test "accepts backends shared with the alert owner and rechecks access at execution", %{
    user: user
  } do
    membership = insert(:team_user, email: user.email)
    backend = query_backend(membership.team.user)
    assert {:ok, alert} = Alerting.create_alert_query(user, attrs(backend))

    Repo.delete!(membership)
    reject(Tesla.Adapter.Finch, :call, 2)

    assert {:error, %{"errorType" => "invalid_backend"}} = Alerting.execute_alert_query(alert)
  end

  test "does not transitively grant the owner's backend access to a shared-alert editor", %{
    user: owner
  } do
    owner_membership = insert(:team_user, email: owner.email)
    backend = query_backend(owner_membership.team.user)
    actor = insert(:user)
    insert(:team_user, email: actor.email, team: insert(:team, user: owner))
    assert {:ok, alert} = Alerting.create_alert_query(owner, attrs(backend), actor: owner)
    assert Alerting.get_alert_query_by_user_access(actor, alert.id).id == alert.id

    assert {:error, changeset} = Alerting.create_alert_query(owner, attrs(backend), actor: actor)
    assert errors_on(changeset).query_backend_id != []

    assert {:error, changeset} = Alerting.update_alert_query(alert, %{query: "up"}, actor: actor)
    assert errors_on(changeset).query_backend_id != []
    refute Alerting.change_alert_query(alert, %{query: "up"}, actor: actor).valid?

    reject(Tesla.Adapter.Finch, :call, 2)

    assert {:error, %{"errorType" => "invalid_backend"}} =
             Alerting.execute_alert_query(alert, actor: actor)

    assert {:error, message} = Alerting.trigger_alert_now(alert, actor: actor)
    assert is_binary(message)
    assert Alerting.list_future_jobs(alert.id) == []

    assert {:ok, %{enabled: false}} =
             Alerting.update_alert_query(alert, %{enabled: false}, actor: actor)
  end

  test "disabling does not allow unauthorized query or notification changes", %{user: owner} do
    owner_membership = insert(:team_user, email: owner.email)
    backend = query_backend(owner_membership.team.user)
    actor = insert(:user)
    insert(:team_user, email: actor.email, team: insert(:team, user: owner))
    assert {:ok, alert} = Alerting.create_alert_query(owner, attrs(backend), actor: owner)
    notification_backend = insert(:backend, user: owner, type: :incidentio)

    for extra <- [
          %{query: "another_metric"},
          %{webhook_notification_url: "https://example.com/collect"},
          %{slack_hook_url: "https://example.com/slack"},
          %{backends: [notification_backend]}
        ] do
      assert {:error, changeset} =
               Alerting.update_alert_query(alert, Map.put(extra, :enabled, false), actor: actor)

      assert errors_on(changeset).query_backend_id != []
      assert Repo.reload!(alert).enabled
    end

    assert {:error, changeset} =
             Alerting.update_alert_query(alert, %{"enabled" => false, "backends" => []},
               actor: actor
             )

    assert errors_on(changeset).query_backend_id != []

    assert {:ok, %{enabled: false}} =
             Alerting.update_alert_query(alert, %{enabled: false}, actor: actor)
  end

  test "stale alert structs cannot authorize edits or manual runs after backend reassignment", %{
    user: owner,
    backend: original_backend
  } do
    owner_membership = insert(:team_user, email: owner.email)
    restricted_backend = query_backend(owner_membership.team.user)
    actor = insert(:user)
    insert(:team_user, email: actor.email, team: insert(:team, user: owner))

    assert {:ok, stale_alert} =
             Alerting.create_alert_query(owner, attrs(original_backend), actor: actor)

    assert {:ok, current_alert} =
             Alerting.update_alert_query(stale_alert, %{query_backend_id: restricted_backend.id},
               actor: owner
             )

    assert {:error, changeset} =
             Alerting.update_alert_query(stale_alert, %{query: "another_metric"}, actor: actor)

    assert errors_on(changeset).query_backend_id != []
    assert Repo.reload!(current_alert).query == current_alert.query
    assert {:error, message} = Alerting.trigger_alert_now(stale_alert, actor: actor)
    assert is_binary(message)
    assert Alerting.list_future_jobs(current_alert.id) == []
  end

  test "shared-alert editors can use a query backend accessible to both actor and owner", %{
    user: owner,
    backend: backend
  } do
    actor = insert(:user)
    insert(:team_user, email: actor.email, team: insert(:team, user: owner))
    assert {:ok, alert} = Alerting.create_alert_query(owner, attrs(backend), actor: actor)
    assert {:ok, alert} = Alerting.update_alert_query(alert, %{query: "up"}, actor: actor)

    expect(Tesla.Adapter.Finch, :call, fn env, _opts -> respond(env, vector([])) end)
    assert {:ok, %QueryResult{rows: []}} = Alerting.execute_alert_query(alert, actor: actor)
    assert {:ok, %Oban.Job{}} = Alerting.trigger_alert_now(alert, actor: actor)
  end

  test "cached TeamUser actors lose query access immediately when membership is revoked", %{
    user: owner,
    backend: backend
  } do
    actor = insert(:team_user, team: insert(:team, user: owner))
    assert {:ok, alert} = Alerting.create_alert_query(owner, attrs(backend), actor: actor)
    Repo.delete!(actor)

    reject(Tesla.Adapter.Finch, :call, 2)

    assert {:error, %{"errorType" => "invalid_backend"}} =
             Alerting.execute_alert_query(alert, actor: actor)

    assert {:error, message} = Alerting.trigger_alert_now(alert, actor: actor)
    assert is_binary(message)

    assert {:error, changeset} =
             Alerting.update_alert_query(alert, %{query: "another_metric"}, actor: actor)

    assert errors_on(changeset).query_backend_id != []
    assert Alerting.list_future_jobs(alert.id) == []
  end

  test "cached User actors are checked using their current email", %{
    user: owner,
    backend: backend
  } do
    actor = insert(:user)
    insert(:team_user, email: actor.email, team: insert(:team, user: owner))
    assert {:ok, alert} = Alerting.create_alert_query(owner, attrs(backend), actor: actor)
    actor |> Ecto.Changeset.change(email: "changed-#{actor.id}@example.com") |> Repo.update!()

    reject(Tesla.Adapter.Finch, :call, 2)

    assert {:error, %{"errorType" => "invalid_backend"}} =
             Alerting.execute_alert_query(alert, actor: actor)
  end

  test "validates evaluation delay bounds", %{user: user, backend: backend} do
    for delay <- [-1, 86_401, nil, "invalid"] do
      assert {:error, changeset} =
               Alerting.create_alert_query(
                 user,
                 Map.put(attrs(backend), :evaluation_delay_seconds, delay)
               )

      assert errors_on(changeset).evaluation_delay_seconds != []
    end

    for delay <- [0, 86_400] do
      assert {:ok, alert} =
               Alerting.create_alert_query(
                 user,
                 Map.put(attrs(backend), :evaluation_delay_seconds, delay)
               )

      assert alert.evaluation_delay_seconds == delay
    end
  end

  test "clears stale source mappings and query backends when changing language", %{
    user: user,
    backend: backend
  } do
    sql_alert = insert(:alert, user: user, source_mapping: %{"old" => "source"})
    assert {:ok, promql_alert} = Alerting.update_alert_query(sql_alert, attrs(backend))
    assert promql_alert.source_mapping == nil

    assert {:ok, sql_alert} =
             Alerting.update_alert_query(promql_alert, %{language: :bq_sql, query: "select 1"})

    assert sql_alert.query_backend_id == nil
    assert sql_alert.source_mapping in [nil, %{}]
  end

  test "prevents deleting a query backend while an alert references it", %{backend: backend} do
    assert {:error, changeset} = Backends.delete_backend(backend)

    assert errors_on(changeset).query_backend_id == [
             "There are still alerts querying this backend"
           ]
  end

  test "runs an instant query at the scheduled time minus delay and retains label collisions", %{
    alert: alert
  } do
    expect(Tesla.Adapter.Finch, :call, fn env, _opts ->
      assert env.url == "https://8.8.8.8/api/v1/query"

      assert URI.decode_query(env.body) == %{
               "query" => "up == 0",
               "time" => "2026-10-19T12:04:30Z"
             }

      respond(env, vector([sample("0", %{"job" => "api", "value" => "label-value"})]))
    end)

    assert {:ok,
            %QueryResult{
              rows: [
                %{
                  "labels" => %{"job" => "api", "value" => "label-value"},
                  "value" => "0",
                  "timestamp" => 123.5
                }
              ],
              total_rows: 1
            }} = Alerting.execute_alert_query(alert, evaluation_time: @evaluation_time)
  end

  test "previews use the current time minus the configured delay", %{alert: alert} do
    before = DateTime.utc_now() |> DateTime.add(-30, :second)

    expect(Tesla.Adapter.Finch, :call, fn env, _opts ->
      {:ok, time, 0} =
        env.body |> URI.decode_query() |> Map.fetch!("time") |> DateTime.from_iso8601()

      assert DateTime.compare(time, before) in [:eq, :gt]

      assert DateTime.compare(time, DateTime.utc_now() |> DateTime.add(-30, :second)) in [
               :eq,
               :lt
             ]

      respond(env, vector([]))
    end)

    assert {:ok, %QueryResult{rows: [], total_rows: 0}} = Alerting.execute_alert_query(alert)
  end

  test "preserves scalar values, special floating point strings and warnings", %{alert: alert} do
    for value <- ["0", "1e+12", "NaN", "+Inf", "-Inf"] do
      response = %{
        "status" => "success",
        "data" => %{"resultType" => "scalar", "result" => [123.5, value]},
        "warnings" => ["partial data"]
      }

      expect(Tesla.Adapter.Finch, :call, fn env, _opts -> respond(env, response) end)

      assert {:ok,
              %QueryResult{
                rows: [%{"labels" => %{}, "timestamp" => 123.5, "value" => ^value}],
                warnings: ["partial data"]
              }} = Alerting.execute_alert_query(alert)
    end
  end

  test "nonempty zero-valued results trigger notifications on every evaluation", %{alert: alert} do
    alert = %{alert | webhook_notification_url: "https://example.com/notify"}

    expect(Tesla.Adapter.Finch, :call, 2, fn env, _opts ->
      respond(env, vector([sample("0")]))
    end)

    expect(WebhookAdaptor.Client, :send, 2, fn opts ->
      assert %{"result" => [%{"value" => "0", "labels" => %{}}]} = opts[:body]
      {:ok, %Tesla.Env{}}
    end)

    for _ <- 1..2 do
      assert {:ok, %{fired: true, total_rows: 1}} = Alerting.run_alert(alert)
    end
  end

  test "empty results do not notify", %{alert: alert} do
    expect(Tesla.Adapter.Finch, :call, fn env, _opts -> respond(env, vector([])) end)
    reject(WebhookAdaptor.Client, :send, 1)
    reject(SlackAdaptor.Client, :send, 2)

    assert {:ok, %{fired: false, rows: []}} = Alerting.run_alert(alert)
  end

  test "rejects unsupported and malformed responses instead of reporting a healthy result", %{
    alert: alert
  } do
    responses = [
      %{"status" => "success", "data" => %{}},
      %{"status" => "success", "data" => %{"resultType" => "matrix", "result" => []}},
      %{"status" => "success", "data" => %{"resultType" => "string", "result" => [1, "hello"]}},
      vector([%{"metric" => %{}, "histogram" => [123, %{}]}]),
      vector([sample("not-a-number")]),
      vector([sample("1", %{"job" => 123})]),
      vector([%{"metric" => %{}, "value" => ["123", "1"]}]),
      vector([%{"metric" => %{}, "value" => [123, 1]}]),
      Map.put(vector([]), "warnings", "invalid")
    ]

    for response <- responses do
      expect(Tesla.Adapter.Finch, :call, fn env, _opts -> respond(env, response) end)
      assert {:error, %{"error" => message}} = Alerting.run_alert(alert)
      assert is_binary(message)
    end
  end

  test "rejects results beyond the notification limit without silently dropping series", %{
    alert: alert
  } do
    expect(Tesla.Adapter.Finch, :call, fn env, _opts ->
      respond(env, vector(List.duplicate(sample("1"), 1001)))
    end)

    reject(WebhookAdaptor.Client, :send, 1)

    assert {:error, %{"errorType" => "result_limit", "error" => message}} =
             Alerting.run_alert(alert)

    assert message =~ "1000"
  end

  test "rechecks current backend configuration instead of a preloaded copy", %{
    alert: alert,
    backend: backend
  } do
    alert = Alerting.preload_alert_query(alert)
    config = %{"url" => "https://8.8.8.8/api/v1/write"}
    backend |> Ecto.Changeset.change(config_encrypted: config) |> Repo.update!()
    reject(Tesla.Adapter.Finch, :call, 2)
    assert {:error, %{"errorType" => "invalid_backend"}} = Alerting.execute_alert_query(alert)
  end

  test "allows disabling an existing alert when its backend is no longer query-ready", %{
    alert: alert,
    backend: backend
  } do
    backend
    |> Ecto.Changeset.change(config_encrypted: %{"url" => "https://8.8.8.8/api/v1/write"})
    |> Repo.update!()

    assert {:ok, %{enabled: false}} = Alerting.update_alert_query(alert, %{enabled: false})
    assert {:error, changeset} = Alerting.update_alert_query(alert, %{query: "up == 1"})
    assert errors_on(changeset).query_backend_id != []
  end

  test "disabling cannot bypass access checks for new or reassigned query backends", %{
    user: user,
    alert: alert
  } do
    backend = query_backend(insert(:user))

    assert {:error, changeset} =
             Alerting.create_alert_query(user, Map.put(attrs(backend), :enabled, false))

    assert errors_on(changeset).query_backend_id != []

    assert {:error, changeset} =
             Alerting.update_alert_query(alert, %{enabled: false, query_backend_id: backend.id})

    assert errors_on(changeset).query_backend_id != []
  end

  test "invalid unsaved evaluation delays return an error instead of crashing previews", %{
    alert: alert
  } do
    reject(Tesla.Adapter.Finch, :call, 2)

    for delay <- [nil, -1, 86_401, "30"] do
      assert {:error, %{"errorType" => "bad_data"}} =
               Alerting.execute_alert_query(%{alert | evaluation_delay_seconds: delay})
    end
  end

  test "preserves upstream errors as JSON-safe maps", %{alert: alert} do
    expect(Tesla.Adapter.Finch, :call, fn env, _opts ->
      respond(
        env,
        %{"status" => "error", "errorType" => "bad_data", "error" => "invalid expression"},
        422
      )
    end)

    assert {:error, error} = Alerting.execute_alert_query(alert)
    assert error == %{"status" => 422, "errorType" => "bad_data", "error" => "invalid expression"}
    assert {:ok, _json} = Jason.encode(error)
  end

  defp attrs(backend) do
    %{
      name: "Down instances",
      language: :promql,
      query: "up == 0",
      cron: "*/5 * * * *",
      query_backend_id: backend.id
    }
  end

  defp query_backend(
         user,
         config \\ %{"url" => "https://8.8.8.8/api/v1/write", "query_url" => "https://8.8.8.8"}
       ) do
    insert(:backend, user: user, type: :victoria_metrics, config: config)
  end

  defp sample(value, labels \\ %{}), do: %{"metric" => labels, "value" => [123.5, value]}

  defp vector(samples) do
    %{"status" => "success", "data" => %{"resultType" => "vector", "result" => samples}}
  end

  defp respond(env, body, status \\ 200) do
    {:ok, %{env | status: status, body: Jason.encode!(body)}}
  end
end
