defmodule Logflare.Logs.OtelResourceProjectTest do
  use ExUnit.Case, async: true

  alias Logflare.Logs.Otel

  test "scalar and array service attributes do not prevent flat service name extraction" do
    for service <- ["worker", 1, 1.5, true, nil, [], ["worker"], [name: "worker"]] do
      assert Otel.resource_project(%{"service" => service, "service.name" => "flat"}) == "flat"
      assert Otel.resource_project(%{"service" => service}) == nil
    end
  end

  test "nested service names retain precedence and empty maps fall back to the flat key" do
    assert Otel.resource_project(%{"service" => %{"name" => "nested"}, "service.name" => "flat"}) ==
             "nested"

    assert Otel.resource_project(%{"service" => %{}, "service.name" => "flat"}) == "flat"
    assert Otel.resource_project(%{"service.name" => "flat"}) == "flat"
    assert Otel.resource_project(%{}) == nil
  end
end
