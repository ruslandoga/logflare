defmodule LogflareWeb.OAuthControllerTest do
  use LogflareWeb.ConnCase

  alias Logflare.Alerting
  alias Logflare.Backends
  alias Logflare.Repo
  alias Logflare.Sources
  alias LogflareWeb.Auth.OauthController
  alias LogflareWeb.Auth.SlackOauthState

  test "unrecognized provider handling", %{conn: conn} do
    for path <- ["/auth/something", "/auth/something/callback"] do
      conn =
        conn
        |> get(path, %{})

      assert html_response(conn, 302)
      assert conn.assigns.flash["error"] =~ "Authentication error"
    end
  end

  test "oauth2 callback redirect work correctly post-sign in", %{conn: conn} do
    insert(:plan)
    user = insert(:user)
    conn = login_user(conn, user)
    env_oauth_config = Application.get_env(:logflare, ExOauth2Provider)

    # create the oauth2 applications
    admin = insert(:user)

    {:ok, application} =
      ExOauth2Provider.Applications.create_application(
        admin,
        %{
          name: "Cloudflare App",
          redirect_uri: "https://www.cloudflare.com/apps/oauth/",
          scope: "read write",
          secret: "",
          uid: "d8a8af24ada66bfa29477d746d74ae7a8833d80019c6fa285f07fe6159491a5f"
        },
        env_oauth_config
      )

    search =
      URI.encode_query(%{
        scope: "read write",
        response_type: "code",
        redirect_uri: application.redirect_uri,
        client_id: application.uid,
        # additional app metadata should be forwarded
        "user.email": "test@logflare.app",
        "site.name": "test.logflare.app"
      })

    uri = "/oauth/authorize?#{search}"
    conn = get(conn, uri, %{})
    assert html_response(conn, 302)
    assert conn.assigns.flash["error"] == nil
    assert redirected_to(conn) =~ "www.cloudflare.com"
  end

  test "slack oauth2 for adding alert slack hooks", %{conn: conn} do
    insert(:plan)
    user = insert(:user)
    alert_query = insert(:alert, user: user)

    conn =
      conn
      |> login_user(user)
      |> bypass_through(LogflareWeb.Router, [:browser])
      |> assign(:ueberauth_auth, %{
        extra: %{
          raw_info: %{
            token: %{other_params: %{"incoming_webhook" => %{"url" => "https://some-url.com"}}}
          }
        }
      })
      |> get(~p"/auth/slack/callback")
      |> OauthController.callback(%{
        "code" =>
          "893134481777.5938142341456.c62b0cecf9de9bc062290c92267dd94ac6cd99f81f53bf8b0da7ef6d31994077",
        "provider" => "slack",
        "state" =>
          SlackOauthState.sign(user, %{
            "action" => "save_hook_url",
            "alert_query_id" => alert_query.id
          })
      })

    assert html_response(conn, 302)
    assert conn.assigns.flash["info"] =~ "Alert connected to Slack!"
    assert redirected_to(conn) == ~p"/alerts/#{alert_query.id}"
  end

  test "slack oauth2 saves hook url for source with valid signed state", %{conn: conn} do
    insert(:plan, name: "Free")
    user = insert(:user)
    source = insert(:source, user: user)
    slack_hook_url = "https://hooks.slack.example/T00/B00/valid"

    conn =
      conn
      |> login_user(user)
      |> bypass_through(LogflareWeb.Router, [:browser])
      |> assign(:ueberauth_auth, %{
        extra: %{
          raw_info: %{
            token: %{other_params: %{"incoming_webhook" => %{"url" => slack_hook_url}}}
          }
        }
      })
      |> get(~p"/auth/slack/callback")
      |> OauthController.callback(%{
        "provider" => "slack",
        "state" =>
          SlackOauthState.sign(user, %{
            "action" => "save_hook_url",
            "source" => %{"id" => source.id}
          })
      })

    assert html_response(conn, 302)
    assert conn.assigns.flash["info"] =~ "Slack connected!"
    assert Sources.get(source.id).slack_hook_url == slack_hook_url
  end

  test "slack oauth2 cannot redirect PromQL results from an inaccessible query backend", %{
    conn: conn
  } do
    insert(:plan)
    owner = insert(:user)
    owner_membership = insert(:team_user, email: owner.email)
    member = insert(:team_user, team: insert(:team, user: owner))

    backend =
      insert(:backend,
        user: owner_membership.team.user,
        type: :victoria_metrics,
        config: %{url: "https://8.8.8.8/api/v1/write", query_url: "https://8.8.8.8"}
      )

    {:ok, alert} =
      Alerting.create_alert_query(owner, %{
        name: "Unavailable services",
        language: :promql,
        query: "up == 0",
        cron: "*/5 * * * *",
        query_backend_id: backend.id
      })

    assert Alerting.get_alert_query_by_user_access(member, alert.id).id == alert.id
    assert Backends.get_backend_by_user_access(owner, backend.id).id == backend.id
    refute Backends.get_backend_by_user_access(member, backend.id)

    conn =
      conn
      |> login_user(owner, member)
      |> bypass_through(LogflareWeb.Router, [:browser])
      |> assign(:ueberauth_auth, %{
        extra: %{
          raw_info: %{
            token: %{
              other_params: %{"incoming_webhook" => %{"url" => "https://member.example/slack"}}
            }
          }
        }
      })
      |> get(~p"/auth/slack/callback")
      |> OauthController.callback(%{
        "provider" => "slack",
        "state" =>
          SlackOauthState.sign(member, %{
            "action" => "save_hook_url",
            "alert_query_id" => alert.id
          })
      })

    assert redirected_to(conn) == ~p"/alerts/#{alert.id}"
    assert conn.assigns.flash["error"] == "Something went wrong!"
    assert Repo.reload!(alert).slack_hook_url == nil
  end

  test "slack oauth2 rejects unsigned plain-JSON state", %{conn: conn} do
    insert(:plan, name: "Free")
    user = insert(:user)
    source = insert(:source, user: user)
    slack_hook_url = "https://hooks.slack.example/T00/B00/unsigned"

    conn =
      conn
      |> login_user(user)
      |> bypass_through(LogflareWeb.Router, [:browser])
      |> assign(:ueberauth_auth, %{
        extra: %{
          raw_info: %{
            token: %{other_params: %{"incoming_webhook" => %{"url" => slack_hook_url}}}
          }
        }
      })
      |> get(~p"/auth/slack/callback")
      |> OauthController.callback(%{
        "provider" => "slack",
        "state" =>
          Jason.encode!(%{
            "action" => "save_hook_url",
            "source" => %{"id" => source.id}
          })
      })

    assert html_response(conn, 302)
    assert conn.assigns.flash["error"] =~ "Authentication error"
    refute Sources.get(source.id).slack_hook_url == slack_hook_url
  end

  test "slack oauth2 rejects state signed for a different user", %{conn: conn} do
    insert(:plan, name: "Free")
    attacker = insert(:user)
    victim = insert(:user)
    victim_source = insert(:source, user: victim)
    slack_hook_url = "https://attacker.example/slack-hook"

    state_signed_by_attacker =
      SlackOauthState.sign(attacker, %{
        "action" => "save_hook_url",
        "source" => %{"id" => victim_source.id}
      })

    conn =
      conn
      |> login_user(victim)
      |> bypass_through(LogflareWeb.Router, [:browser])
      |> assign(:ueberauth_auth, %{
        extra: %{
          raw_info: %{
            token: %{other_params: %{"incoming_webhook" => %{"url" => slack_hook_url}}}
          }
        }
      })
      |> get(~p"/auth/slack/callback")
      |> OauthController.callback(%{
        "provider" => "slack",
        "state" => state_signed_by_attacker
      })

    assert html_response(conn, 302)
    assert conn.assigns.flash["error"] =~ "Authentication error"
    refute Sources.get(victim_source.id).slack_hook_url == slack_hook_url
  end

  describe "bug: ueberauth port does not match url config" do
    setup do
      start_supervised!(Logflare.SystemMetricsSup)
      config = Application.get_env(:logflare, LogflareWeb.Endpoint)

      on_exit(fn ->
        Application.put_env(:logflare, LogflareWeb.Endpoint, config)
      end)

      {:ok, config: config}
    end

    test "navbar OAuth2 link should exclude port if host is provided", %{
      conn: conn,
      config: config
    } do
      updated = Keyword.put(config, :url, host: "www.something.com", port: 3232)
      Application.put_env(:logflare, LogflareWeb.Endpoint, updated)
      conn = conn |> get(Routes.oauth_path(conn, :request, "google"))
      assert redirected_to(conn, 302) =~ "3232"
    end

    test "navbar OAuth2 link should exclude port if host is provided with string port", %{
      conn: conn,
      config: config
    } do
      updated = Keyword.put(config, :url, host: "www.something.com", port: "3232")
      Application.put_env(:logflare, LogflareWeb.Endpoint, updated)
      conn = conn |> get(Routes.oauth_path(conn, :request, "google"))
      assert redirected_to(conn, 302) =~ "3232"
    end
  end
end
