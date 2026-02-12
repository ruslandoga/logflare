defmodule Logflare.SystemMetrics.Schedulers.MeasurementsTest do
  use Logflare.DataCase, async: false
  alias Logflare.SystemMetrics.Schedulers.Measurements

  test "dispatch_utilization emits scheduler utilization telemetry events" do
    telemetry_ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:logflare, :system, :scheduler, :utilization]
      ])

    on_exit(fn -> :telemetry.detach(telemetry_ref) end)

    # First call initializes the persistent_term
    Measurements.dispatch_utilization()

    # Second call should emit events
    Measurements.dispatch_utilization()

    # Should receive at least one event (for each scheduler)
    assert_received {[:logflare, :system, :scheduler, :utilization], ^telemetry_ref, measurements,
                     metadata}

    # Verify measurements structure
    assert Map.has_key?(measurements, :utilization)
    assert Map.has_key?(measurements, :utilization_percentage)

    # Verify metadata structure
    assert Map.has_key?(metadata, :name)
    assert Map.has_key?(metadata, :type)

    # Verify types
    assert is_integer(measurements.utilization)
    assert is_float(measurements.utilization_percentage)
    assert is_binary(metadata.name)
    assert is_binary(metadata.type)

    # Verify type is one of expected values
    assert metadata.type in ["normal", "dirty", "total"]
  end

  test "dispatch_utilization emits events for multiple schedulers" do
    telemetry_ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:logflare, :system, :scheduler, :utilization]
      ])

    on_exit(fn ->
      :telemetry.detach(telemetry_ref)
    end)

    # First call initializes
    Measurements.dispatch_utilization()

    # Second call emits events
    Measurements.dispatch_utilization()

    # Collect all events (should be multiple, one per scheduler + total)
    events = collect_events(telemetry_ref, [], 100)

    # Should have at least 2 events (normal schedulers + total)
    assert length(events) >= 2

    # Should have a "total" event
    total_events = Enum.filter(events, fn {_, _, _, metadata} -> metadata.type == "total" end)
    assert length(total_events) > 0

    # Should have "normal" scheduler events
    normal_events = Enum.filter(events, fn {_, _, _, metadata} -> metadata.type == "normal" end)
    assert length(normal_events) > 0
  end

  defp collect_events(_ref, acc, 0), do: Enum.reverse(acc)

  defp collect_events(ref, acc, remaining) do
    receive do
      {event_name, ^ref, measurements, metadata} ->
        collect_events(ref, [{event_name, ref, measurements, metadata} | acc], remaining - 1)
    after
      50 -> Enum.reverse(acc)
    end
  end
end
