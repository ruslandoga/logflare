defmodule Logflare.ContextCacheTest do
  use Logflare.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Logflare.ContextCache
  alias Logflare.ContextCache.TransactionBroadcaster
  alias Logflare.Sources
  alias Logflare.Sources.Source
  alias Logflare.Backends
  alias Logflare.Backends.Backend
  alias Logflare.Auth

  describe "ContextCache" do
    setup do
      insert(:plan, name: "Free")
      user = insert(:user)
      source = insert(:source, user: user)
      %{source: source, user: user}
    end

    test "bust_keys/1, does nothing for empty list" do
      assert {:ok, 0} = ContextCache.bust_keys([])
    end

    test "apply_fun/3,  bust_keys/1 by :id field of value", %{source: source} do
      Sources.Cache.get_by(token: source.token)
      cache_key = {:get_by, [[token: source.token]]}
      assert {:cached, %Source{}} = Cachex.get!(Sources.Cache, cache_key)

      assert {:ok, 1} = ContextCache.bust_keys([{Sources, source.id}])
      assert is_nil(Cachex.get!(Sources.Cache, cache_key))
    end

    test "apply_fun/3,  bust_keys/1 by :id field of value for :ok tuple", %{user: user} do
      {:ok, key} = Auth.create_access_token(user)
      assert {:ok, _token, _user} = Auth.Cache.verify_access_token(key.token)
      cache_key = {:verify_access_token, [key.token]}
      assert {:cached, {:ok, %_{}, _user}} = Cachex.get!(Auth.Cache, cache_key)

      assert {:ok, 1} = ContextCache.bust_keys([{Auth, key.id}])
      assert is_nil(Cachex.get!(Auth.Cache, cache_key))
    end

    test "apply_fun/3, bust_keys/1 if primary key is in list of returned structs", %{
      source: source
    } do
      backend = insert(:backend, sources: [source])
      Backends.Cache.list_backends(source_id: source.id)
      cache_key = {:list_backends, [[source_id: source.id]]}
      assert {:cached, [%Backend{}]} = Cachex.get!(Backends.Cache, cache_key)

      assert {:ok, 1} = ContextCache.bust_keys([{Backends, backend.id}])
      assert is_nil(Cachex.get!(Backends.Cache, cache_key))
    end
  end

  describe "unboxed transaction" do
    setup do
      on_exit(fn ->
        SQL.Sandbox.unboxed_run(Logflare.Repo, fn ->
          for u <- Logflare.Repo.all(Logflare.User) do
            Logflare.Repo.delete(u)
          end
        end)
      end)

      :ok
    end

    test "TransactionBroadcaster subscribes to wal and broadcasts transactions" do
      ContextCache.CacheBuster.subscribe_to_transactions()
      broadcaster = start_supervised!(TransactionBroadcaster)
      TestUtils.send_and_wait_for_handling(broadcaster, :try_subscribe)
      publisher = ContextCache.Supervisor.publisher_name()
      assert broadcaster in :sys.get_state(publisher).subscribers

      user =
        SQL.Sandbox.unboxed_run(Logflare.Repo, fn ->
          insert(:user)
        end)

      user_id = Integer.to_string(user.id)

      assert_receive %Cainophile.Changes.Transaction{
                       changes: [
                         %Cainophile.Changes.NewRecord{
                           relation: {_schema, "users"},
                           record: %{"id" => ^user_id}
                         }
                       ]
                     },
                     1_000
    end
  end
end
