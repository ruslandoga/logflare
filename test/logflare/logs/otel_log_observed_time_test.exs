defmodule Logflare.Logs.OtelLogObservedTimeTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.OtelLog
  alias Opentelemetry.Proto.Logs.V1.LogRecord
  alias Opentelemetry.Proto.Logs.V1.ResourceLogs
  alias Opentelemetry.Proto.Logs.V1.ScopeLogs

  test "occurrence time takes precedence over observation time" do
    assert %{"timestamp" => 123, "observed_time_unix_nano" => 456} =
             convert(%LogRecord{time_unix_nano: 123, observed_time_unix_nano: 456})
  end

  test "observation time is used when occurrence time is absent" do
    assert %{"timestamp" => 456, "observed_time_unix_nano" => 456} =
             convert(%LogRecord{observed_time_unix_nano: 456})
  end

  test "missing timestamps allow receiver time inference" do
    event = convert(%LogRecord{})
    refute Map.has_key?(event, "timestamp")
    assert event["observed_time_unix_nano"] == nil
  end

  @spec convert(LogRecord.t()) :: map()
  defp convert(record) do
    [event] =
      OtelLog.handle_batch([%ResourceLogs{scope_logs: [%ScopeLogs{log_records: [record]}]}], nil)

    event
  end
end
