defmodule Logflare.Sources.Source.EmailNotificationServerTest do
  @moduledoc false
  use Logflare.DataCase

  alias Logflare.Sources.Source.EmailNotificationServer

  setup do
    u1 = insert(:user)
    s1 = insert(:source, user_id: u1.id, notifications_every: 10)
    [source: s1, user: u1]
  end

  describe "GenServer" do
    test "start_link/1", %{source: source} do
      start_supervised!({EmailNotificationServer, source: source})
    end

    test "init/1", %{source: source} do
      EmailNotificationServer.init(source: source)
      assert_receive :check_rate, 1_000
    end
  end
end
