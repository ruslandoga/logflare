defmodule Logflare.Alerting.PromqlIntegrationTest do
  use Logflare.DataCase, async: false
  use Oban.Testing, repo: Logflare.Repo

  import Logflare.VictoriaMetricsTestHelpers

  alias Logflare.Alerting
  alias Logflare.Alerting.AlertWorker
  alias Logflare.Backends.Backend

  @moduletag :victoria_metrics
  @retry [sleep: 250, duration: 30_000]

  setup_all :ensure_vm_available
  setup :setup_vm

  setup %{backend: backend, source: source} do
    backend =
      backend
      |> Backend.changeset(%{config: Map.put(backend.config, :query_url, vm_base_url())})
      |> Repo.update!()

    test_pid = self()

    receiver =
      start_supervised!(
        {Bandit,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         plug: fn conn, _opts ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:notification, conn.method, conn.request_path, Jason.decode!(body)})
           Plug.Conn.send_resp(conn, 200, "ok")
         end}
      )

    {:ok, {_address, notification_port}} = ThousandIsland.listener_info(receiver)
    vm_port = URI.parse(vm_base_url()).port

    stub(Finch, :build, fn method, url, headers, body ->
      Mimic.call_original(Finch, :build, [method, url, headers, body])
    end)

    stub(Finch, :request, fn request, pool, opts ->
      if request.host == "127.0.0.1" and request.port in [vm_port, notification_port] do
        Mimic.call_original(Finch, :request, [request, pool, opts])
      else
        {:error, :unexpected_external_request}
      end
    end)

    metric_name =
      "promql_alert_" <> String.replace(Ecto.UUID.generate(), "-", "") <> ".queue.depth"

    query_name = String.replace(metric_name, ".", "_")
    timestamp = System.system_time(:second) - 120

    events =
      for {worker, previous_value} <- [{"worker-a", 0}, {"worker-b", 5}],
          {sample_time, value} <- [{timestamp, previous_value}, {timestamp + 20, 20}] do
        metric_params(
          event_message: metric_name,
          metric_type: "gauge",
          value: value,
          timestamp: sample_time * 1_000_000_000,
          attributes: %{"worker" => worker, "http.route" => "/queue"}
        )
      end

    assert {:ok, 4} = submit(events, source)

    TestUtils.retry_assert(@retry, fn ->
      series = export(source)
      assert length(series) == 2

      assert Enum.all?(
               series,
               &(&1["timestamps"] == [timestamp * 1_000, (timestamp + 20) * 1_000])
             )
    end)

    [
      backend: backend,
      query: ~s(#{query_name}{source="#{source.name}"}),
      timestamp: timestamp,
      notification_url: "http://127.0.0.1:#{notification_port}/alert"
    ]
  end

  test "scheduled alerts query ingested samples at the delayed time and deliver zero-valued matches",
       %{
         backend: backend,
         source: source,
         query: query,
         timestamp: timestamp,
         notification_url: notification_url
       } do
    job = create_job(source.user, backend.id, query <> " < 10", timestamp, notification_url)

    assert :ok = perform_job(job)
    assert_receive {:notification, "POST", "/alert", %{"result" => rows}}, 5_000

    assert length(rows) == 2

    assert Map.new(rows, fn row ->
             assert row["timestamp"] == timestamp
             assert row["labels"]["source"] == source.name
             assert row["labels"]["_http_route"] == "/queue"
             {row["labels"]["worker"], row["value"]}
           end) == %{"worker-a" => "0", "worker-b" => "5"}

    assert %{"result" => %{"fired" => true, "rows" => ^rows, "total_rows" => 2}} =
             Repo.reload!(job).meta

    refute_receive {:notification, _, _, _}
  end

  test "scheduled alerts with no matching series store a successful result without notifying", %{
    backend: backend,
    source: source,
    query: query,
    timestamp: timestamp,
    notification_url: notification_url
  } do
    job = create_job(source.user, backend.id, query <> " > 10", timestamp, notification_url)

    assert :ok = perform_job(job)

    assert %{"result" => %{"fired" => false, "rows" => [], "total_rows" => 0}} =
             Repo.reload!(job).meta

    refute_receive {:notification, _, _, _}
  end

  @spec create_job(Logflare.User.t(), integer(), String.t(), integer(), String.t()) ::
          Oban.Job.t()
  defp create_job(user, backend_id, query, timestamp, notification_url) do
    {:ok, alert} =
      Alerting.create_alert_query(user, %{
        name: "PromQL integration alert",
        language: :promql,
        query: query,
        query_backend_id: backend_id,
        evaluation_delay_seconds: 30,
        cron: "*/5 * * * *",
        webhook_notification_url: notification_url
      })

    scheduled_at = DateTime.from_unix!(timestamp + 30)

    job =
      %{alert_query_id: alert.id, scheduled_at: DateTime.to_iso8601(scheduled_at)}
      |> AlertWorker.new(scheduled_at: scheduled_at)
      |> Oban.insert!()
      |> Repo.reload!()

    %{job | attempt: 1, attempted_at: DateTime.utc_now()}
  end
end
