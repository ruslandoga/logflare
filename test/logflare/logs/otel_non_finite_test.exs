defmodule Logflare.Logs.OtelNonFiniteTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.Otel
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.ArrayValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Common.V1.KeyValueList

  test "normalizes non-finite protobuf doubles inside nested arrays and maps" do
    value = %AnyValue{
      value:
        {:array_value,
         %ArrayValue{
           values: [
             %AnyValue{value: {:double_value, :nan}},
             %AnyValue{
               value:
                 {:kvlist_value,
                  %KeyValueList{
                    values: [
                      %KeyValue{
                        key: "positive",
                        value: %AnyValue{value: {:double_value, :infinity}}
                      },
                      %KeyValue{
                        key: "negative",
                        value: %AnyValue{value: {:double_value, :negative_infinity}}
                      }
                    ]
                  }}
             }
           ]
         }}
    }

    decoded = value |> Protobuf.encode() |> Protobuf.decode(AnyValue)
    result = Otel.extract_value(decoded)

    assert result == ["NaN", %{"positive" => "Infinity", "negative" => "-Infinity"}]
    assert result |> Jason.encode!() |> Jason.decode!() == result
  end

  test "normalizes bare non-finite atoms used by metric datapoints" do
    assert Otel.extract_value(:nan) == "NaN"
    assert Otel.extract_value(:infinity) == "Infinity"
    assert Otel.extract_value(:negative_infinity) == "-Infinity"
  end

  test "preserves finite doubles, integers, nil, and empty values" do
    assert Otel.extract_value(%AnyValue{value: {:double_value, 1.25}}) == 1.25
    assert Otel.extract_value(1.25) == 1.25
    assert Otel.extract_value(%AnyValue{value: {:int_value, 42}}) == 42
    assert Otel.extract_value(%AnyValue{value: {:string_value, ""}}) == ""
    assert Otel.extract_value(%AnyValue{value: {:array_value, %ArrayValue{}}}) == []
    assert Otel.extract_value(%AnyValue{value: {:kvlist_value, %KeyValueList{}}}) == %{}
    assert Otel.extract_value(%AnyValue{}) == nil
    assert Otel.extract_value(nil) == nil
  end
end
