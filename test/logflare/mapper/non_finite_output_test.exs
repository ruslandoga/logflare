defmodule Logflare.Mapper.NonFiniteOutputTest do
  use ExUnit.Case, async: true

  alias Logflare.Mapper
  alias Logflare.Mapper.OtelDefaults

  @envelope {"00000000-0000-0000-0000-000000000000", "", "", 0}
  @config_id "00000000-0000-0000-0000-000000000000"

  setup_all do
    {:ok,
     compiled:
       Map.new([:map, :ch_row_binary, :ndjson], fn output ->
         {output, Mapper.compile!(OtelDefaults.for_type(:metric, output))}
       end)}
  end

  test "preserves non-finite scalars and arrays across map, NDJSON, and RowBinary outputs", %{
    compiled: compiled
  } do
    cases = [
      {"NaN", "NaN", 0x7FF8000000000000},
      {"Infinity", "Infinity", 0x7FF0000000000000},
      {"-Infinity", "-Infinity", 0xFFF0000000000000},
      {"1e999", "Infinity", 0x7FF0000000000000},
      {"-1e999", "-Infinity", 0xFFF0000000000000},
      {"1.25", 1.25, 0x3FF4000000000000}
    ]

    for {input, expected, bits} <- cases do
      payload = %{
        "metric_type" => "histogram",
        "timestamp" => 0,
        "value" => input,
        "sum" => input,
        "min" => input,
        "max" => input,
        "explicit_bounds" => [input],
        "exemplars" => [%{"value" => input}]
      }

      expected_fields = %{
        "value" => expected,
        "sum" => expected,
        "min" => expected,
        "max" => expected,
        "explicit_bounds" => [expected],
        "exemplars.value" => [expected]
      }

      mapped = Mapper.map(payload, compiled.map)
      assert Map.take(mapped, Map.keys(expected_fields)) == expected_fields
      assert {:ok, _} = Jason.encode(mapped)

      ndjson =
        payload
        |> Mapper.map(compiled.ndjson, output_context: {:ndjson, @config_id, @envelope})
        |> Jason.decode!()

      assert Map.take(ndjson, Map.keys(expected_fields)) == expected_fields

      row =
        Mapper.map(payload, compiled.ch_row_binary,
          output_context: {:ch_row_binary, <<0::128>>, @envelope}
        )

      scalar_and_bucket_values =
        <<bits::little-unsigned-64, 0::64, bits::little-unsigned-64, bits::little-unsigned-64,
          bits::little-unsigned-64, 0::32, 0::64, 0::32, 0::32, 0, 1, bits::little-unsigned-64>>

      assert :binary.match(row, scalar_and_bucket_values) != :nomatch
    end
  end
end
