defmodule Logflare.Logs.OtelBytesTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.Otel
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.ArrayValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Common.V1.KeyValueList

  test "arbitrary bytes remain JSON encodable inside nested attributes" do
    bytes = %AnyValue{value: {:bytes_value, <<0, 255, 254>>}}
    array = %AnyValue{value: {:array_value, %ArrayValue{values: [bytes]}}}

    nested = %AnyValue{
      value: {:kvlist_value, %KeyValueList{values: [%KeyValue{key: "bytes", value: array}]}}
    }

    assert Otel.extract_value(nested) == %{"bytes" => ["AP/+"]}
    assert Jason.encode!(Otel.extract_value(nested)) == ~s({"bytes":["AP/+"]})
    assert Otel.extract_value(%AnyValue{value: {:bytes_value, ""}}) == ""
  end

  test "UTF-8 bytes are base64 encoded while string values remain text" do
    assert Otel.extract_value(%AnyValue{value: {:bytes_value, "hello"}}) == "aGVsbG8="
    assert Otel.extract_value(%AnyValue{value: {:string_value, "hello"}}) == "hello"
  end
end
