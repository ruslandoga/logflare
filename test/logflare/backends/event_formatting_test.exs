defmodule Logflare.Backends.EventFormattingTest do
  use Logflare.DataCase, async: false

  alias GoogleApi.BigQuery.V2.Model.TableDataInsertAllResponse
  alias Logflare.Backends.Adaptor.WebhookAdaptor.Client
  alias Logflare.Backends.IngestEventQueue
  alias Logflare.Backends.SourceSup
  alias Logflare.Google.BigQuery
  alias Logflare.Logs.Processor
  alias Logflare.Logs.Raw
  alias Logflare.Logs.Validators.BigQuerySchemaChange
  alias Logflare.SourceSchemas
  alias Logflare.SystemMetrics.AllLogsLogged

  @schema_rejection [:logflare, :backends, :bigquery, :schema_rejection]

  setup do
    start_supervised!(AllLogsLogged)
    insert(:plan)
    user = insert(:user)

    source =
      insert(:source,
        user: user,
        lock_schema: true,
        validate_schema: true,
        bq_storage_write_api: false
      )

    previous = Application.get_env(:logflare, BigQuerySchemaChange, [])
    Application.put_env(:logflare, BigQuerySchemaChange, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:logflare, BigQuerySchemaChange, previous) end)

    assert {:ok, _schema} =
             SourceSchemas.create_or_update_source_schema(source, %{
               bigquery_schema:
                 TestUtils.build_bq_schema(%{"attributes" => %{"_http_route" => ""}}),
               schema_flat_map: %{
                 "attributes" => :map,
                 "attributes._http_route" => :string,
                 "event_message" => :string
               }
             })

    stub(BigQuery, :get_table, fn _ -> {:error, :not_found} end)

    insert(:backend,
      type: :webhook,
      user: user,
      sources: [source],
      config: %{url: "https://example.com/events", http: "http1"}
    )

    TestUtils.attach_forwarder(@schema_rejection)
    start_supervised!({SourceSup, source})
    [source: source]
  end

  test "BigQuery formatting and schema rejection leave webhook and shared events unchanged", %{
    source: source
  } do
    test_pid = self()

    expect(BigQuery, :stream_batch!, fn _context, rows ->
      {:ok, stored} = IngestEventQueue.fetch_events({source.id, nil}, 10)
      send(test_pid, {:bigquery_rows, rows, stored})
      {:ok, %TableDataInsertAllResponse{insertErrors: nil}}
    end)

    expect(Client, :send, fn opts ->
      send(test_pid, {:webhook_events, opts[:body]})
      {:ok, %Tesla.Env{status: 204}}
    end)

    valid = event_params("/checkout")
    invalid = event_params(42)
    without_message = event_params("/checkout") |> Map.delete("event_message")
    valid_id = valid["id"]
    invalid_id = invalid["id"]
    without_message_id = without_message["id"]
    params = [valid, invalid, without_message]

    assert {:ok, 3} = Processor.ingest(params, Raw, source)

    assert_receive {:bigquery_rows, rows, stored}, 5_000
    assert Enum.sort(Enum.map(rows, & &1.insertId)) == Enum.sort([valid_id, without_message_id])

    for row <- rows do
      assert row.json["attributes"] == [%{"_http_route" => "/checkout", "__1_key" => "digit"}]
      assert row.json["resource"] == [%{"_service_name" => "checkout"}]
    end

    assert Enum.find(rows, &(&1.insertId == without_message_id)).json["event_message"] == nil

    assert Enum.sort(Enum.map(stored, & &1.id)) ==
             Enum.sort([valid_id, invalid_id, without_message_id])

    original_by_id = Map.new(params, &{&1["id"], &1})

    for event <- stored do
      assert event.body_format == :original
      assert event.valid
      assert event.pipeline_error == nil
      assert event.body["attributes"] == original_by_id[event.id]["attributes"]
      assert event.body["resource"] == original_by_id[event.id]["resource"]
    end

    source_id = source.id

    assert_receive {:telemetry_event, @schema_rejection, %{count: 1}, %{source_id: ^source_id}},
                   5_000

    assert_receive {:webhook_events, events}, 5_000

    assert Enum.sort(Enum.map(events, & &1["id"])) ==
             Enum.sort([valid_id, invalid_id, without_message_id])

    for event <- events do
      assert event["attributes"] == original_by_id[event["id"]]["attributes"]
      assert event["resource"] == original_by_id[event["id"]]["resource"]
      assert event["event_message"] == original_by_id[event["id"]]["event_message"]
    end

    TestUtils.retry_assert(fn ->
      recent = IngestEventQueue.list_recent_events({source.id, nil}, 10)
      assert Enum.sort(Enum.map(recent, & &1.id)) == Enum.sort([valid_id, without_message_id])

      for event <- recent do
        assert event.body_format == :original
        assert event.body["attributes"] == original_by_id[event.id]["attributes"]
        assert event.body["resource"] == original_by_id[event.id]["resource"]
      end
    end)
  end

  @spec event_params(String.t() | integer()) :: map()
  defp event_params(route) do
    %{
      "id" => Ecto.UUID.generate(),
      "event_message" => "formatting boundary",
      "timestamp" => System.system_time(:nanosecond),
      "attributes" => %{"http.route" => route, "1.key" => "digit"},
      "resource" => %{"service.name" => "checkout"}
    }
  end
end
