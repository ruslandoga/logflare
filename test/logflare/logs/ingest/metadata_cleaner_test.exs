defmodule Logflare.Logs.Ingest.MetadataCleanerTest do
  use ExUnit.Case

  alias Logflare.LogEvent.Size
  alias Logflare.Logs.Ingest.MetadataCleaner, as: Cleaner
  alias LogflareWeb.Logs.PayloadTestUtils

  describe "clean_with_byte_size/1" do
    test "preserves original keys and non-empty values while removing nested empties" do
      input = %{
        "service.name" => "api",
        "service-name" => "worker",
        "_service_name" => "literal",
        "1.key" => %{"λ" => "hé", "empty" => %{"nested" => [nil, "", [], %{}, {}]}},
        "values" => [nil, false, 0, %{"retained" => "x", "removed" => []}],
        "removed" => [[nil, %{"empty" => ""}]]
      }

      expected = %{
        "service.name" => "api",
        "service-name" => "worker",
        "_service_name" => "literal",
        "1.key" => %{"λ" => "hé"},
        "values" => [false, 0, %{"retained" => "x"}]
      }

      assert Cleaner.clean_with_byte_size(input) == {expected, 22}
      assert Cleaner.deep_reject_nil_and_empty(input) == expected
    end

    test "keeps list order and counts scalar values without keys or containers" do
      input = [nil, "hé", -123, 1.5, true, false, :warn, {}, %{"a long key" => [1000, nil]}]
      expected = ["hé", -123, 1.5, true, false, :warn, %{"a long key" => [1000]}]

      assert Cleaner.clean_with_byte_size(input) == {expected, 20}
      assert Cleaner.deep_reject_nil_and_empty(input) == expected
      assert Cleaner.clean_with_byte_size(%{"short" => expected}) == {%{"short" => expected}, 20}
    end

    test "returns zero bytes for empty maps and lists, including recursively empty values" do
      for input <- [%{}, %{"nested" => [[%{"empty" => nil}], "", {}, []]}] do
        assert Cleaner.clean_with_byte_size(input) == {%{}, 0}
      end

      for input <- [[], [nil, "", [], %{}, {}, [[%{"empty" => nil}]]]] do
        assert Cleaner.clean_with_byte_size(input) == {[], 0}
      end
    end

    test "retains non-JSON values and their fallback size accounting" do
      input = %{"date" => ~D[2026-10-23], "tuple" => {:tag, 1}, "empty" => nil}
      expected = Map.delete(input, "empty")

      assert Cleaner.clean_with_byte_size(input) == {expected, Size.body_byte_size(expected)}
      assert Cleaner.deep_reject_nil_and_empty(input) == expected
    end
  end

  describe "metadata payload cleaner" do
    test "removes nils from standard cloudlare metadata" do
      meta_with_nils =
        PayloadTestUtils.standard_metadata(:cloudflare)
        |> put_in(~w(request cf country), nil)
        |> put_in(~w(request cf colo), "")
        |> put_in(~w(request headers host), %{})
        |> put_in(~w(response headers vary), [])

      meta_cleaned = Cleaner.deep_reject_nil_and_empty(meta_with_nils)

      get_keys_in = &Map.keys(get_in(meta_cleaned, &1))

      assert Map.keys(meta_cleaned["request"]) == ~w[cf headers method url]
      assert "colo" not in get_keys_in.(~w(request cf))
      assert "country" not in get_keys_in.(~w(request cf))
      assert "host" not in get_keys_in.(~w(request headers))
      assert "vary" not in get_keys_in.(~w(response headers))
    end

    test "removes nils from standard elixir logger exception metadata" do
      meta_with_nils =
        PayloadTestUtils.standard_metadata(:elixir_logger_exception)
        |> update_in(
          ["stacktrace"],
          fn xs ->
            for map <- xs do
              %{map | "line" => nil, "module" => [], "arity_or_args" => %{}, "function" => ""}
            end
          end
        )
        |> update_in(["stacktrace"], &(&1 ++ [%{}, nil, [], "", {}]))
        |> put_in(["pid"], nil)

      meta_cleaned = Cleaner.deep_reject_nil_and_empty(meta_with_nils)

      assert length(meta_cleaned["stacktrace"]) == 2
      assert "pid" not in Map.keys(meta_cleaned)
      assert "line" not in Map.keys(hd(meta_cleaned["stacktrace"]))
    end

    test "removes nested empty containers" do
      meta_with_nils = %{"lists" => %{"nested" => [[]]}, "lists_not_empty" => ["1337"]}
      meta_cleaned = Cleaner.deep_reject_nil_and_empty(meta_with_nils)

      assert meta_cleaned == %{"lists_not_empty" => ["1337"]}

      meta_with_nils = %{
        "request" => %{
          "cf" => %{
            "asn" => 15_169,
            "clientTrustScore" => 1,
            "colo" => [""],
            "country" => nil
          }
        }
      }

      meta_cleaned = Cleaner.deep_reject_nil_and_empty(meta_with_nils)

      assert meta_cleaned == %{
               "request" => %{"cf" => %{"asn" => 15_169, "clientTrustScore" => 1}}
             }

      meta_with_nils =
        PayloadTestUtils.standard_metadata(:cloudflare)
        |> put_in(~w(request cf country), nil)
        |> put_in(~w(request cf colo), [""])
        |> put_in(~w(request headers host), %{"lists" => [[]]})
        |> put_in(~w(request headers host2), %{"lists" => %{"lists2" => [[]]}, "lists1.1" => [""]})
        |> put_in(~w(response headers vary), [["", [[]]]])
        |> put_in(~w(response headers vary2), [["", [[[["", [], [%{}]]]]]]])

      meta_cleaned = Cleaner.deep_reject_nil_and_empty(meta_with_nils)

      get_keys_in = &Map.keys(get_in(meta_cleaned, &1))

      assert Map.keys(meta_cleaned["request"]) == ~w[cf headers method url]
      assert "colo" not in get_keys_in.(~w(request cf))
      assert "country" not in get_keys_in.(~w(request cf))
      assert "host" not in get_keys_in.(~w(request headers))
      assert "vary" not in get_keys_in.(~w(response headers))
      assert "vary2" not in get_keys_in.(~w(response headers))
    end
  end
end
