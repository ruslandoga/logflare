defmodule Logflare.Logs.OtelTrace do
  @moduledoc """
  Converts a list of Otel ResourceSpans to a list of Logflare events

  * One ResourceSpans can contain multiple ScopeSpans
  * One ScopeSpans can contain multiple Spans
  * One Span can contain multiple Events
  * A Log Event is created for each Span and each Event
  """

  @behaviour Logflare.Logs.Processor

  alias Logflare.Logs.Otel
  alias Opentelemetry.Proto.Trace.V1.ResourceSpans
  alias Opentelemetry.Proto.Trace.V1.ScopeSpans
  alias Opentelemetry.Proto.Trace.V1.Span
  alias Opentelemetry.Proto.Trace.V1.Span.Event
  alias Opentelemetry.Proto.Trace.V1.Span.Link
  alias Opentelemetry.Proto.Trace.V1.Status

  @spec handle_batch([ResourceSpans.t()], Logflare.Sources.Source.t()) :: [map()]
  def handle_batch(resource_spans, _source) when is_list(resource_spans) do
    Enum.flat_map(resource_spans, &handle_resource_span/1)
  end

  @spec handle_resource_span(ResourceSpans.t()) :: [map()]
  defp handle_resource_span(%ResourceSpans{
         resource: resource,
         scope_spans: scope_spans,
         schema_url: schema_url
       }) do
    base_event = %{
      "resource" => Otel.handle_resource(resource),
      "resource_schema_url" => schema_url,
      "resource_dropped_attributes_count" =>
        if(resource, do: resource.dropped_attributes_count, else: 0)
    }

    Enum.flat_map(scope_spans, &handle_scope_span(&1, base_event))
  end

  @spec handle_scope_span(ScopeSpans.t(), map()) :: [map()]
  defp handle_scope_span(%{scope: scope, spans: spans, schema_url: schema_url}, base_event) do
    base_event =
      Map.merge(base_event, %{
        "scope" => Otel.handle_scope(scope),
        "scope_schema_url" => schema_url
      })

    Enum.flat_map(spans, &handle_span(&1, base_event))
  end

  @spec handle_span(Span.t(), map()) :: [map()]
  defp handle_span(span, base_event) do
    metadata = %{"type" => "span"}
    events = Enum.map(span.events, &handle_span_event/1)
    log_events = Enum.map(events, &handle_event(&1, span, base_event))

    [
      Map.merge(base_event, %{
        "event_message" => span.name,
        "metadata" => metadata,
        "span_id" => Base.encode16(span.span_id, case: :lower),
        "parent_span_id" => Base.encode16(span.parent_span_id, case: :lower),
        "trace_id" => Base.encode16(span.trace_id, case: :lower),
        "trace_state" => span.trace_state,
        "flags" => span.flags,
        "kind" => span_kind(span.kind),
        "start_time" => span.start_time_unix_nano,
        "end_time" => span.end_time_unix_nano,
        "time_unix_nano" => Otel.timestamp_or_nil(span.start_time_unix_nano),
        "start_time_unix_nano" => Otel.timestamp_or_nil(span.start_time_unix_nano),
        "end_time_unix_nano" => Otel.timestamp_or_nil(span.end_time_unix_nano),
        "attributes" => Otel.handle_attributes(span.attributes),
        "dropped_attributes_count" => span.dropped_attributes_count,
        "events" => events,
        "dropped_events_count" => span.dropped_events_count,
        "links" => Enum.map(span.links, &handle_link/1),
        "dropped_links_count" => span.dropped_links_count,
        "status" => handle_status(span.status),
        "timestamp" => span.start_time_unix_nano,
        "project" => Otel.resource_project(base_event["resource"])
      })
    ] ++ log_events
  end

  @spec handle_event(map(), Span.t(), map()) :: map()
  defp handle_event(event, span, base_event) do
    metadata = %{"type" => "event"}

    Map.merge(base_event, %{
      "event_message" => event["name"],
      "metadata" => metadata,
      "span_id" => Base.encode16(span.span_id, case: :lower),
      "parent_span_id" => Base.encode16(span.span_id, case: :lower),
      "trace_id" => Base.encode16(span.trace_id, case: :lower),
      "trace_flags" => Bitwise.band(span.flags, 255),
      "attributes" => event["attributes"],
      "dropped_attributes_count" => event["dropped_attributes_count"],
      "time_unix_nano" => Otel.timestamp_or_nil(event["time_unix_nano"]),
      "timestamp" => event["time_unix_nano"],
      "project" => Otel.resource_project(base_event["resource"])
    })
  end

  @spec handle_span_event(Event.t()) :: map()
  defp handle_span_event(event) do
    %{
      "name" => event.name,
      "time_unix_nano" => event.time_unix_nano,
      "attributes" => Otel.handle_attributes(event.attributes),
      "dropped_attributes_count" => event.dropped_attributes_count
    }
  end

  @spec handle_link(Link.t()) :: map()
  defp handle_link(link) do
    %{
      "trace_id" => Base.encode16(link.trace_id, case: :lower),
      "span_id" => Base.encode16(link.span_id, case: :lower),
      "trace_state" => link.trace_state,
      "flags" => link.flags,
      "attributes" => Otel.handle_attributes(link.attributes),
      "dropped_attributes_count" => link.dropped_attributes_count
    }
  end

  @spec handle_status(Status.t() | nil) :: map()
  defp handle_status(nil), do: %{"code" => "UNSET", "message" => ""}

  defp handle_status(status) do
    %{"code" => status_code(status.code), "message" => status.message}
  end

  @spec status_code(Status.StatusCode.t()) :: String.t() | integer()
  defp status_code(code) when code in [:STATUS_CODE_UNSET, 0], do: "UNSET"
  defp status_code(code) when code in [:STATUS_CODE_OK, 1], do: "OK"
  defp status_code(code) when code in [:STATUS_CODE_ERROR, 2], do: "ERROR"
  defp status_code(code) when is_integer(code), do: code

  @spec span_kind(Span.SpanKind.t()) :: String.t()
  defp span_kind(kind) when kind in [:SPAN_KIND_INTERNAL, 1], do: "Internal"
  defp span_kind(kind) when kind in [:SPAN_KIND_SERVER, 2], do: "Server"
  defp span_kind(kind) when kind in [:SPAN_KIND_CLIENT, 3], do: "Client"
  defp span_kind(kind) when kind in [:SPAN_KIND_PRODUCER, 4], do: "Producer"
  defp span_kind(kind) when kind in [:SPAN_KIND_CONSUMER, 5], do: "Consumer"
  defp span_kind(_kind), do: "Unspecified"
end
