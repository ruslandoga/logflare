defmodule Logflare.Logs.OtelTrace do
  @moduledoc """
  Converts a list of Otel ResourceSpans to a list of Logflare events

  * One ResourceSpans can contain multiple ScopeSpans
  * One ScopeSpans can contain multiple Spans
  * One Span can contain multiple Events
  * A Log Event is created for each Span and each Event
  """

  alias Logflare.Logs.Otel

  alias Opentelemetry.Proto.Trace.V1.ResourceSpans
  @behaviour Logflare.Logs.Processor

  def handle_batch(resource_spans, _source) when is_list(resource_spans) do
    Enum.flat_map(resource_spans, &handle_resource_span/1)
  end

  defp handle_resource_span(%ResourceSpans{
         resource: resource,
         scope_spans: scope_spans,
         schema_url: schema_url
       }) do
    metadata = %{
      "resource_schema_url" => schema_url,
      "resource_dropped_attributes_count" =>
        Map.get(resource || %{}, :dropped_attributes_count, 0)
    }

    resource = Otel.handle_resource(resource)

    scope_spans
    |> Enum.flat_map(&handle_scope_span(&1, resource))
    |> Enum.map(&Map.merge(&1, metadata))
  end

  defp handle_scope_span(%{scope: scope, spans: spans, schema_url: schema_url}, resource) do
    scope = Otel.handle_scope(scope)

    spans
    |> Enum.flat_map(&handle_span(&1, resource, scope))
    |> Enum.map(&Map.put(&1, "scope_schema_url", schema_url))
  end

  defp handle_span(span, resource, scope) do
    metadata = %{"type" => "span"}
    events = Enum.map(span.events, &handle_event(&1, span, resource, scope))

    [
      %{
        "event_message" => span.name,
        "metadata" => metadata,
        "resource" => resource,
        "scope" => scope,
        "span_id" => Base.encode16(span.span_id, case: :lower),
        "parent_span_id" => Base.encode16(span.parent_span_id, case: :lower),
        "trace_id" => Base.encode16(span.trace_id, case: :lower),
        "kind" => span_kind(span.kind),
        "start_time" => span.start_time_unix_nano,
        "end_time" => span.end_time_unix_nano,
        "attributes" => Otel.handle_attributes(span.attributes),
        "timestamp" => span.start_time_unix_nano,
        "project" => Otel.resource_project(resource)
      }
    ] ++ events
  end

  defp handle_event(event, %{span_id: span_id, trace_id: trace_id}, resource, scope) do
    metadata = %{"type" => "event"}

    %{
      "event_message" => event.name,
      "metadata" => metadata,
      "resource" => resource,
      "scope" => scope,
      "parent_span_id" => Base.encode16(span_id),
      "trace_id" => Base.encode16(trace_id, case: :lower),
      "attributes" => Otel.handle_attributes(event.attributes),
      "timestamp" => event.time_unix_nano,
      "project" => Otel.resource_project(resource)
    }
  end

  @spec span_kind(Opentelemetry.Proto.Trace.V1.Span.SpanKind.t()) :: String.t()
  defp span_kind(:SPAN_KIND_INTERNAL), do: "Internal"
  defp span_kind(:SPAN_KIND_SERVER), do: "Server"
  defp span_kind(:SPAN_KIND_CLIENT), do: "Client"
  defp span_kind(:SPAN_KIND_PRODUCER), do: "Producer"
  defp span_kind(:SPAN_KIND_CONSUMER), do: "Consumer"
  defp span_kind(_kind), do: "Unspecified"
end
