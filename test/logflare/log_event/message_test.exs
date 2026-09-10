defmodule Logflare.LogEvent.MessageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Logflare.LogEvent
  alias Logflare.Sources.Source

  @alphas [?a..?z, ?A..?Z]

  describe "make_message/2" do
    property "if pattern is `nil` then the message is left as is" do
      check all message <- string(:printable) do
        le = event_with_message(nil, %{"message" => message})

        assert message == le.body["event_message"]
      end
    end

    test "message `id` is accessible" do
      le = event_with_message("id", %{})

      assert "#{le.id}" == le.body["event_message"]
    end

    test "pattern `message` and `event_message` can be used interchangeably" do
      for a <- ~w[message event_message],
          b <- ~w[message event_message] do
        message = "#{a} -> #{b}"
        le = event_with_message(a, %{b => message})

        assert message == le.body["event_message"]
      end
    end

    property "one can concat multiple fields" do
      check all message <- string(:printable) do
        le = event_with_message("id, message", %{"message" => message})

        assert "#{le.id} | #{message}" == le.body["event_message"]
      end
    end

    property "`m.` can be used as an alias for `metadata.`" do
      check all key <- string(@alphas, min_length: 1),
                data <- string(:printable) do
        le1 = event_with_message("m.#{key}", %{"metadata" => %{key => data}})
        le2 = event_with_message("metadata.#{key}", le1)

        assert le1.body == le2.body
      end
    end

    property "top keys are reachable" do
      check all metadata <-
                  map_of(
                    string(@alphas, min_length: 1),
                    string(:printable),
                    min_length: 1
                  ) do
        key = Enum.random(Map.keys(metadata))

        le = event_with_message(key, metadata)

        assert Jason.encode!(metadata[key]) == le.body["event_message"]
      end
    end

    property "nested keys are reachable" do
      check all metadata <-
                  map_of(
                    string(@alphas, min_length: 2),
                    map_of(
                      string(@alphas, min_length: 1),
                      string(:printable, min_length: 1, max_length: 20),
                      min_length: 1,
                      max_length: 20
                    ),
                    min_length: 1,
                    max_length: 50
                  ) do
        first = Enum.random(Map.keys(metadata))
        second = Enum.random(Map.keys(metadata[first]))

        le = event_with_message("#{first}.#{second}", metadata)

        assert Jason.encode!(metadata[first][second]) == le.body["event_message"]
      end
    end
  end

  @spec event_with_message(String.t() | nil, LogEvent.t() | map()) :: LogEvent.t()
  defp event_with_message(pattern, %LogEvent{} = le) do
    LogEvent.apply_custom_event_message(
      le,
      %Source{custom_event_message_keys: pattern}
    )
  end

  defp event_with_message(pattern, %{} = body) do
    le = %LogEvent{
      id: Ecto.UUID.generate(),
      body: body
    }

    event_with_message(pattern, le)
  end
end
