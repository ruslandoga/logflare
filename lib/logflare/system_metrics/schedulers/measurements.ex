defmodule Logflare.SystemMetrics.Schedulers.Measurements do
  @moduledoc """
  Handles scheduler utilization measurements for telemetry_poller.

  This module maintains state via persistent_term to track the previous
  scheduler sample, which is required to calculate utilization between samples.
  """

  alias Logflare.SystemMetrics.Schedulers

  @persistent_term_key {__MODULE__, :last_sample}

  @doc """
  Dispatches scheduler utilization telemetry events.

  This function is called periodically by telemetry_poller.
  """
  def dispatch_utilization do
    current_sample = :scheduler.sample()

    case :persistent_term.get(@persistent_term_key, nil) do
      nil ->
        # First run, just store the sample
        :persistent_term.put(@persistent_term_key, current_sample)

      last_sample ->
        # Calculate and emit metrics
        scheduler_metrics = Schedulers.scheduler_utilization(last_sample, current_sample)

        Enum.each(scheduler_metrics, fn metric ->
          :telemetry.execute(
            [:logflare, :system, :scheduler, :utilization],
            %{
              utilization: metric.utilization,
              utilization_percentage: metric.utilization_percentage
            },
            %{name: metric.name, type: metric.type}
          )
        end)

        # Store current sample for next iteration
        :persistent_term.put(@persistent_term_key, current_sample)
    end
  end
end
