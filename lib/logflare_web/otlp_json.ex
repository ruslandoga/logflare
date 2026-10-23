defmodule LogflareWeb.OtlpJson do
  @moduledoc """
  Decodes OTLP JSON with hexadecimal trace and span identifiers.
  """

  alias Protobuf.FieldProps

  @spec decode(binary(), module()) :: {:ok, struct()} | {:error, Exception.t()}
  def decode(body, schema) do
    with {:ok, data} <- Jason.decode(body) do
      data
      |> normalize_message(schema)
      |> Protobuf.JSON.from_decoded(schema)
    end
  end

  @spec normalize_message(term(), module()) :: term()
  defp normalize_message(data, schema) when is_map(data) do
    Enum.reduce(schema.__message_props__().field_props, data, fn {_number, field}, acc ->
      field_names = Enum.uniq([Atom.to_string(field.name_atom), field.json_name])

      Enum.reduce(field_names, acc, fn name, fields ->
        Map.replace_lazy(fields, name, &normalize_field(&1, field))
      end)
    end)
  end

  defp normalize_message(data, _schema), do: data

  @spec normalize_field(term(), FieldProps.t()) :: term()
  defp normalize_field(values, %FieldProps{repeated?: true} = field) when is_list(values) do
    Enum.map(values, &normalize_singular(&1, field))
  end

  defp normalize_field(value, field), do: normalize_singular(value, field)

  @spec normalize_singular(term(), FieldProps.t()) :: term()
  defp normalize_singular(value, %FieldProps{type: :bytes, name_atom: name})
       when name in [:trace_id, :span_id, :parent_span_id] and is_binary(value) do
    expected_bytes = if name == :trace_id, do: 16, else: 8

    with {:ok, bytes} <- Base.decode16(value, case: :mixed),
         true <- byte_size(bytes) in [0, expected_bytes] do
      Base.encode64(bytes)
    else
      _ ->
        raise ArgumentError,
              "Invalid OTLP #{name}: expected #{expected_bytes * 2} hexadecimal characters"
    end
  end

  defp normalize_singular(value, %FieldProps{embedded?: true, type: schema}) do
    normalize_message(value, schema)
  end

  defp normalize_singular(value, _field), do: value
end
