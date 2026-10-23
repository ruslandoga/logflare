defmodule Logflare.Logs.OtelLogMetadataTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelLog
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Logs.V1.LogRecord
  alias Opentelemetry.Proto.Logs.V1.ResourceLogs
  alias Opentelemetry.Proto.Logs.V1.ScopeLogs

  test "event names, raw flags, trace flags and dropped counts survive conversion" do
    event =
      convert(%LogRecord{
        event_name: "checkout",
        flags: 0x301,
        dropped_attributes_count: 3,
        body: %AnyValue{value: {:string_value, "body text"}}
      })

    assert event["event_name"] == "checkout"
    assert event["event_message"] == "body text"
    assert event["flags"] == 0x301
    assert event["trace_flags"] == 1
    assert event["dropped_attributes_count"] == 3
  end

  test "numeric known and unknown severities pass through without crashing the batch" do
    for {severity, expected} <- [{:SEVERITY_NUMBER_INFO, 9}, {9, 9}, {99, 99}, {-1, -1}] do
      assert convert(%LogRecord{severity_number: severity})["severity_number"] == expected
    end

    assert convert(%LogRecord{event_name: "event"})["event_message"] == "event"
  end

  @spec convert(LogRecord.t()) :: map()
  defp convert(record) do
    [event] =
      OtelLog.handle_batch([%ResourceLogs{scope_logs: [%ScopeLogs{log_records: [record]}]}], nil)

    event
  end
end
