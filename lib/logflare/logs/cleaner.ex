defmodule Logflare.Logs.Ingest.MetadataCleaner do
  @moduledoc """
  Deeply rejects nils and empty containers in nested enumerables.
  """

  alias Logflare.LogEvent.Size

  defguardp nil_or_empty(x) when x in [%{}, [], "", {}, nil]

  @spec deep_reject_nil_and_empty(map() | [term()]) :: map() | [term()]
  def deep_reject_nil_and_empty(data) when is_map(data) or is_list(data) do
    {cleaned, _bytes} = clean_with_byte_size(data)
    cleaned
  end

  @spec clean_with_byte_size(map() | [term()]) :: {map() | [term()], non_neg_integer()}
  def clean_with_byte_size(data) when is_map(data) do
    {cleaned, bytes} =
      :maps.fold(
        fn
          _key, value, acc when nil_or_empty(value) ->
            acc

          key, value, {body, bytes} when is_map(value) or is_list(value) ->
            {cleaned, value_bytes} = clean_with_byte_size(value)

            if nil_or_empty(cleaned),
              do: {body, bytes},
              else: {Map.put(body, key, cleaned), bytes + value_bytes}

          key, value, {body, bytes} ->
            {Map.put(body, key, value), bytes + Size.body_byte_size(value)}
        end,
        {%{}, 0},
        data
      )

    if is_struct(cleaned), do: {cleaned, Size.body_byte_size(cleaned)}, else: {cleaned, bytes}
  end

  def clean_with_byte_size(data) when is_list(data), do: clean_list(data, [], 0)

  @spec clean_list([term()], [term()], non_neg_integer()) :: {[term()], non_neg_integer()}
  defp clean_list([], items, bytes), do: {Enum.reverse(items), bytes}

  defp clean_list([value | rest], items, bytes) when nil_or_empty(value),
    do: clean_list(rest, items, bytes)

  defp clean_list([value | rest], items, bytes) when is_map(value) or is_list(value) do
    {cleaned, value_bytes} = clean_with_byte_size(value)

    if nil_or_empty(cleaned),
      do: clean_list(rest, items, bytes),
      else: clean_list(rest, [cleaned | items], bytes + value_bytes)
  end

  defp clean_list([value | rest], items, bytes),
    do: clean_list(rest, [value | items], bytes + Size.body_byte_size(value))

  @spec nil_or_empty?(term()) :: boolean()
  def nil_or_empty?(x) when nil_or_empty(x), do: true
  def nil_or_empty?(_), do: false
end
