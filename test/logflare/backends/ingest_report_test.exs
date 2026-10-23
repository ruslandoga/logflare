defmodule Logflare.Backends.IngestReportTest do
  use Logflare.DataCase, async: false

  alias Logflare.Backends
  alias Logflare.LogEvent
  alias Logflare.LogEvent.PipelineError
  alias Logflare.SystemMetrics.AllLogsLogged

  setup do
    insert(:plan)
    start_supervised!(AllLogsLogged)
    source = insert(:source, user: insert(:user))
    %{source: source}
  end

  test "reports original input positions and retains the legacy error result", %{source: source} do
    rejected = %LogEvent{
      source_id: source.id,
      source_uuid: source.token,
      body: %{"event_message" => "invalid"},
      valid: false,
      pipeline_error: %PipelineError{stage: "test", type: "test", message: "invalid value"}
    }

    dropped = %{rejected | drop: true}

    other_rejected = %{
      rejected
      | pipeline_error: %{rejected.pipeline_error | message: "other error"}
    }

    batch = [dropped, rejected, dropped, other_rejected]

    assert {:ok,
            %{
              accepted: 0,
              rejections: [{1, "invalid value"}, {3, "other error"}]
            }} = Backends.ingest_logs_with_rejections(batch, source, nil, false)

    assert {:error, ["other error", "invalid value"]} = Backends.ingest_logs(batch, source)
  end

  test "reports every future timestamp rejection while preserving legacy drops", %{source: source} do
    future_timestamp = System.system_time(:microsecond) + 7_200_000_000

    event = %LogEvent{
      source_id: source.id,
      source_uuid: source.token,
      valid: true,
      body: %{"event_message" => "future", "timestamp" => future_timestamp}
    }

    assert {:ok, %{accepted: 0, rejections: [{0, message}, {1, message}]}} =
             Backends.ingest_logs_with_rejections([event, event], source, nil, false)

    assert message =~ "future"
    assert {:ok, 0} = Backends.ingest_logs([event, event], source)
  end

  test "an empty batch is fully accepted", %{source: source} do
    assert {:ok, %{accepted: 0, rejections: []}} =
             Backends.ingest_logs_with_rejections([], source, nil, false)

    assert {:ok, 0} = Backends.ingest_logs([], source)
  end
end
