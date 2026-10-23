defmodule Logflare.Logs.ProcessorTest do
  use Logflare.DataCase, async: true

  alias Logflare.Backends
  alias Logflare.Logs.OtelLog
  alias Logflare.Logs.OtelMetric
  alias Logflare.Logs.OtelTrace
  alias Logflare.Logs.Processor

  setup do
    Mimic.stub(Backends, :start_for_ingest, fn _source -> :ok end)
    %{source: build(:source)}
  end

  test "counts a span once when its span and derived event records reject", %{source: source} do
    [resource] = TestUtilsGrpc.random_resource_span()
    [scope] = resource.scope_spans
    [span] = scope.spans
    event = hd(span.events)
    span = %{span | events: [event, event]}
    resources = [%{resource | scope_spans: [%{scope | spans: [span, span]}]}]

    for {indices, expected} <- [{[0, 1, 2, 4, 5], 2}, {[1, 2], 1}, {[], 0}] do
      Mimic.stub(Backends, :ingest_logs_with_rejections, fn batch, ^source, nil, true ->
        assert batch == OtelTrace.handle_batch(resources, source)
        rejections = Enum.map(indices, &{&1, "invalid span attribute"})
        {:ok, %{accepted: length(batch) - length(indices), rejections: rejections}}
      end)

      assert {:ok, %{rejected: ^expected}} =
               Processor.ingest_with_report(resources, OtelTrace, source)
    end
  end

  test "counts rejected log records and metric data points individually", %{source: source} do
    for {processor, resources} <- [
          {OtelLog, TestUtilsGrpc.random_otel_logs_request().resource_logs},
          {OtelMetric, TestUtilsGrpc.random_otel_metrics_request().resource_metrics}
        ] do
      Mimic.stub(Backends, :ingest_logs_with_rejections, fn batch, ^source, nil, true ->
        assert batch == processor.handle_batch(resources, source)
        {:ok, %{accepted: length(batch) - 1, rejections: [{0, "invalid value"}]}}
      end)

      assert {:ok, %{rejected: 1, errors: ["invalid value"]}} =
               Processor.ingest_with_report(resources, processor, source)
    end
  end

  test "preserves dispatch errors and the original ingest API", %{source: source} do
    resources = TestUtilsGrpc.random_resource_span()

    Mimic.stub(Backends, :ingest_logs_with_rejections, fn _batch, ^source, nil, true ->
      {:error, :spool_unavailable}
    end)

    assert {:error, :spool_unavailable} =
             Processor.ingest_with_report(resources, OtelTrace, source)

    Mimic.stub(Backends, :ingest_logs, fn batch, ^source, nil, true -> {:ok, length(batch)} end)
    assert {:ok, 2} = Processor.ingest(resources, OtelTrace, source)
  end
end
