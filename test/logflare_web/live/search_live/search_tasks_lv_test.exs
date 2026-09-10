defmodule LogflareWeb.Source.SearchTasksLVTest do
  use LogflareWeb.ConnCase, async: true, isolated: true

  alias GoogleApi.BigQuery.V2.Model.TableFieldSchema, as: TFS
  alias GoogleApi.BigQuery.V2.Model.TableSchema, as: TS
  alias Logflare.Backends.Adaptor.BigQueryAdaptor
  alias Logflare.Backends.Adaptor.ClickHouseAdaptor
  alias Logflare.Backends.Adaptor.PostgresAdaptor
  alias Logflare.Backends.QueryError
  alias Logflare.Google.BigQuery.SchemaUtils
  alias Logflare.SavedSearches.Cache, as: SavedSearchesCache
  alias Logflare.Sources.Source.BigQuery.SchemaBuilder
  alias LogflareWeb.Source.SearchLV

  @default_querystring "c:count(*) c:group_by(t::minute)"

  setup {LogflareWeb.SearchLiveTestGuard, :setup}

  defp setup_mocks(_ctx) do
    stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, opts ->
      query = opts[:body].query

      response = %{
        "event_message" => Jason.encode!(%{"message" => "some event message"})
      }

      response =
        if query =~ "user_id" do
          Map.put(response, "user_id", "123")
        else
          response
        end

      {:ok, TestUtils.gen_bq_response(response)}
    end)

    :ok
  end

  defp setup_user_session(%{conn: conn, user: user, plan: plan}) do
    _billing_account = insert(:billing_account, user: user, stripe_plan_id: plan.stripe_id)

    user = user |> Logflare.Repo.preload([:billing_account, :team])
    conn = conn |> login_user(user)

    [conn: conn]
  end

  describe "search tasks" do
    setup context do
      user = insert(:user)

      source_attrs =
        [user: user, bigquery_clustering_fields: "user_id"]
        |> Keyword.merge(Map.get(context, :source_attrs, []))

      source = insert(:source, source_attrs)
      plan = insert(:plan)

      bq_schema =
        Map.get(context, :source_schema, TestUtils.build_bq_schema(%{"user_id" => "some_value"}))

      insert(:source_schema,
        source: source,
        bigquery_schema: bq_schema,
        schema_flat_map: SchemaUtils.bq_schema_to_flat_typemap(bq_schema)
      )

      [user: user, source: source, plan: plan]
    end

    setup [:setup_mocks, :setup_user_session]

    test "subheader - lql docs", %{conn: conn, source: source} do
      {:ok, view, _html} =
        live_with_redirect(conn, ~p"/sources/#{source.id}/search?querystring=something123")

      assert view
             |> element("a", "LQL")
             |> render_click() =~ "Event Message Filtering"
    end

    test "subheader - schema modal", %{conn: conn, source: source} do
      {:ok, view, _html} = live_with_redirect(conn, ~p"/sources/#{source.id}/search")

      assert view
             |> element(".subhead a", "schema")
             |> render_click() =~ "event_message"
    end

    test "subheader - events", %{conn: conn, source: source} do
      {:ok, view, _html} = live_with_redirect(conn, ~p"/sources/#{source.id}/search")

      assert view
             |> element(".subhead a", "events")
             |> render_click()

      view
      |> TestUtils.wait_for_render(".search-query-debug")

      html = render(view)
      assert html =~ "Actual SQL query used when querying for results"

      formatted_sql =
        """
        select
          t0.timestamp
        """
        |> String.trim()

      assert html =~ formatted_sql

      {:error, {:redirect, %{to: dest}}} =
        view
        |> element("a.btn.btn-primary", "Edit as query")
        |> render_click()

      assert dest =~ "/query?q=SELECT"
    end

    test "subheader - aggregeate", %{conn: conn, source: source} do
      {:ok, view, _html} = live_with_redirect(conn, ~p"/sources/#{source.id}/search")

      assert view
             |> element(".subhead a", "aggregate")
             |> render_click()

      view
      |> TestUtils.wait_for_render("#logflare-modal #search-query-debug p")

      html = render(view)

      assert html =~ "Actual SQL query used when querying for results"

      formatted_sql =
        """
        select
          (
            case
        """
        |> String.trim()

      assert html =~ formatted_sql
    end

    test "subheader - saved searches", %{conn: conn, source: source} do
      {:ok, view, _html} = live_with_redirect(conn, ~p"/sources/#{source.id}/search")

      assert view
             |> element(".subhead a", "saved")
             |> render_click()

      view
      |> TestUtils.wait_for_render("#logflare-modal")

      assert view
             |> has_element?("#logflare-modal #saved-searches-empty")

      saved_search = insert(:saved_search, %{source: source})

      _ = SavedSearchesCache.bust_by(source_id: saved_search.source_id)
      {:ok, view, _html} = live_with_redirect(conn, ~p"/sources/#{source.id}/search")

      assert view
             |> element(".subhead a", "saved")
             |> render_click()

      view
      |> TestUtils.wait_for_render("#logflare-modal")

      view
      |> TestUtils.wait_for_render("#logflare-modal #saved-searches-list")

      assert view
             |> has_element?("#logflare-modal #saved-searches-list", saved_search.querystring)
    end

    test "load page", %{conn: conn, source: source} do
      {:ok, view, html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))

      assert html =~ "~/logs/"
      assert html =~ source.name
      assert html =~ "/search"

      view
      |> TestUtils.wait_for_render("#logs-list-container li[data-event-id]")

      html = view |> element("#logs-list-container") |> render()
      assert html =~ "some event message"

      html = render(view)
      assert html =~ "Elapsed since last query"

      assert view
             |> has_element?("#logs-list-container a", "permalink")

      # permalink should have timestamp query parameter
      assert view
             |> element("#logs-list-container a", ~r/permalink/)

      assert view
             |> has_element?("#logs-list-container a[href*='timestamp']", "permalink")

      assert view
             |> has_element?("#logs-list-container a[href*='uuid']", "permalink")

      # includes recommended fields in permalink
      assert view |> element("#logs-list-container a[href]", "permalink") |> render =~
               URI.encode_query(%{"lql" => "user_id:123 c:count(*) c:group_by(t::minute)"})

      # default input values
      assert find_selected_chart_period(html) == "minute"
      assert find_chart_aggregate(html) == "count"

      querystring = find_querystring(html)

      assert querystring =~ "c:count(*) c:group_by(t::minute)"
    end

    @tag source_attrs: [default_search_lql: "s:m.level"]
    test "appends source default LQL when querystring param is absent", %{
      conn: conn,
      source: source
    } do
      {:ok, _view, html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))

      querystring = find_querystring(html)

      assert querystring =~ "s:m.level"
      assert querystring =~ "c:count(*) c:group_by(t::minute)"
    end

    @tag source_attrs: [default_search_lql: "s:m.level"]
    test "appends source default LQL to an empty querystring", %{
      conn: conn,
      source: source
    } do
      {:ok, _view, html} =
        live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id, querystring: ""))

      querystring = find_querystring(html)

      assert querystring =~ "s:m.level"
      assert querystring =~ "c:count(*) c:group_by(t::minute)"
    end

    @tag source_attrs: [default_search_lql: "s:m.level"]
    test "does not append default LQL to querystring param", %{
      conn: conn,
      source: source
    } do
      {:ok, _view, html} =
        live_with_redirect(
          conn,
          Routes.live_path(conn, SearchLV, source.id, querystring: "error")
        )

      querystring = find_querystring(html)

      assert querystring =~ "error"
      refute querystring =~ "s:m.level"
    end

    @tag source_attrs: [default_search_lql: "s:m.level"]
    test "does not append default LQL when removed from query", %{
      conn: conn,
      source: source
    } do
      {:ok, view, html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))

      assert find_querystring(html) =~ "s:m.level"

      render_change(view, :start_search, %{
        "querystring" => "c:count(*) c:group_by(t::minute) error"
      })

      html = render(view)
      refute find_querystring(html) =~ "s:m.level"
      assert find_querystring(html) =~ "error"
    end

    test "query field has schema fields and saved searches", %{
      conn: conn,
      source: source
    } do
      query_a = "metadata.level:error"
      query_b = "tags:active"

      insert(:saved_search, source: source, querystring: query_a)
      insert(:saved_search, source: source, querystring: query_b)

      bq_schema =
        TestUtils.build_bq_schema(%{
          "message" => "string",
          "metadata" => %{
            "flags" => [true],
            "store" => %{"zip" => 123}
          }
        })

      schema_flat_map = SchemaUtils.bq_schema_to_flat_typemap(bq_schema)

      source_schema = Logflare.SourceSchemas.get_source_schema_by(source_id: source.id)

      {:ok, _source_schema} =
        Logflare.SourceSchemas.update_source_schema(source_schema, %{
          bigquery_schema: bq_schema,
          schema_flat_map: schema_flat_map
        })

      _ = SavedSearchesCache.bust_by(source_id: source.id)

      {:ok, view, _html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))

      html =
        view
        |> TestUtils.wait_for_render("#lql-editor-hook")
        |> render()

      {:ok, document} = Floki.parse_document(html)

      [schema_fields_json] =
        document
        |> Floki.find("#lql-editor-hook")
        |> Floki.attribute("data-schema-fields-json")

      [saved_searches_json] =
        document
        |> Floki.find("#lql-editor-hook")
        |> Floki.attribute("data-suggested-searches-json")

      assert {:ok, schema_fields} = Jason.decode(schema_fields_json)
      assert {:ok, saved_searches} = Jason.decode(saved_searches_json)

      assert schema_fields["metadata.flags"] == "list[boolean]"
      assert schema_fields["metadata.store.zip"] == "integer"

      assert query_a in saved_searches
      assert query_b in saved_searches
    end

    test "empty results message", %{conn: conn, source: source} do
      pid = self()

      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, opts ->
        query = opts[:body].query

        if query =~ ~r/COUNT\(|COUNTIF\(/i do
          send(pid, {:agg_query, query})
          {:ok, TestUtils.gen_bq_response([])}
        else
          send(pid, {:event_query, query})
          {:ok, TestUtils.gen_bq_response([])}
        end
      end)

      {:ok, view, _html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))

      view
      |> TestUtils.wait_for_render("#source-logs-search-list")

      assert_receive {:event_query, _query}
      assert_receive {:agg_query, _query}

      TestUtils.retry_assert(fn ->
        html = view |> element("#logs-list-container") |> render()

        assert html =~ "No events matching your query"
        refute html =~ "Extend search"
      end)
    end

    test "extend search button shows when aggregate results have hits", %{
      conn: conn,
      source: source
    } do
      pid = self()

      zero_dt = ~U[2026-01-30 06:46:41Z]
      hits_dt = ~U[2026-01-30 06:47:41Z]

      zero_ts_exp = TestUtils.gen_bq_timestamp(zero_dt)
      hits_ts_exp = TestUtils.gen_bq_timestamp(hits_dt)

      expected_zero_ts =
        zero_dt
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()
        |> String.trim_trailing("Z")

      expected_hits_ts =
        hits_dt
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()
        |> String.trim_trailing("Z")

      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, opts ->
        query = opts[:body].query

        if query =~ ~r/COUNT\(|COUNTIF\(/i do
          send(pid, {:agg_query, query})
          aggregate_schema = Logflare.TestUtils.build_bq_schema(%{"value" => "INTEGER"})

          rows =
            [
              %{"timestamp" => zero_ts_exp, "value" => 0},
              %{"timestamp" => hits_ts_exp, "value" => 5}
            ]

          {:ok, TestUtils.gen_bq_response(rows, aggregate_schema)}
        else
          send(pid, {:event_query, query})
          {:ok, TestUtils.gen_bq_response([])}
        end
      end)

      {:ok, view, _html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))

      view
      |> TestUtils.wait_for_render("#source-logs-search-list")

      assert_receive {:event_query, _query}
      assert_receive {:agg_query, _query}

      TestUtils.retry_assert(fn ->
        assert view |> element("#logs-list-container") |> render() =~ "Extend search"
      end)

      html = view |> element("#logs-list-container") |> render()

      assert html =~ "No events matching your query"

      {:ok, document} = Floki.parse_document(html)

      assert [link] =
               document
               |> Floki.find("a")
               |> Enum.filter(fn link -> Floki.text(link) =~ "Extend search" end)

      assert Floki.text(document) =~ "t:>=#{expected_hits_ts}"
      refute Floki.text(document) =~ "t:>=#{expected_zero_ts}"

      href =
        link
        |> Floki.attribute("href")
        |> hd()

      uri = URI.parse(href)
      assert uri.path == "/sources/#{source.id}/search"

      query_params = URI.decode_query(uri.query)
      assert query_params["tailing?"] == "false"
      assert query_params["querystring"] =~ "t:>=#{expected_hits_ts}"
    end

    test "page title includes source name", %{conn: conn, source: source} do
      {:ok, _view, html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))
      assert html =~ "<title>#{source.name} | Logflare"
    end

    test "lql filters", %{conn: conn, source: source} do
      {:ok, view, _html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))
      pid = self()

      view
      |> TestUtils.wait_for_render("#logs-list-container li[data-event-id]")

      html = view |> element("#logs-list-container") |> render()
      assert html =~ "some event message"

      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, opts ->
        params = opts[:body].queryParameters

        if length(params) > 2 do
          assert Enum.any?(params, fn param -> param.parameterValue.value == "crasher" end)
          assert Enum.any?(params, fn param -> param.parameterValue.value == "error" end)
        end

        send(pid, {:query_request, opts[:body]})
        {:ok, TestUtils.gen_bq_response(%{"event_message" => "some error message"})}
      end)

      render_change(view, :querystring_changed, %{
        "querystring" => "c:count(*) c:group_by(t::minute) error crasher"
      })

      view
      |> TestUtils.wait_for_render("#logs-list-container li[data-event-id]")

      render_change(view, :start_search, %{
        "querystring" => "c:count(*) c:group_by(t::minute) error crasher"
      })

      # wait for async search task to complete
      view
      |> TestUtils.wait_for_render("#logs-list-container li[data-event-id]")

      html = view |> element("#logs-list-container") |> render()

      assert html =~ "some error message"
      refute html =~ "some event message"

      assert_receive {:query_request,
                      %_{jobCreationMode: "JOB_CREATION_OPTIONAL", parameterMode: "POSITIONAL"}}
    end

    test "count distinct aggregation", %{conn: conn, source: source} do
      pid = self()

      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, opts ->
        if opts[:body].query =~ "COUNT(DISTINCT" do
          send(pid, {:ok, :countd})
        end

        {:ok, TestUtils.gen_bq_response(%{"event_message" => "test message"})}
      end)

      {:ok, view, _html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))

      render_change(view, :start_search, %{
        "querystring" => "c:countd(event_message) c:group_by(t::hour)"
      })

      TestUtils.retry_assert(fn ->
        html = view |> element("#logs-list-container") |> render()
        assert html =~ "test message"
        assert_receive {:ok, :countd}
      end)
    end

    test "chart display interval", %{conn: conn, source: source} do
      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, opts ->
        params = opts[:body].queryParameters

        if Enum.any?(params, fn param -> param.parameterValue.value == "MINUTE" end) do
          # truncate by 120 minutes
          assert Enum.any?(params, fn param -> param.parameterValue.value == 120 end)
        end

        {:ok, TestUtils.gen_bq_response()}
      end)

      {:ok, view, _html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))

      # post-init fetching
      view
      |> TestUtils.wait_for_render("#logs-list-container li[data-event-id]")

      render_change(view, :start_search, %{
        "querystring" => @default_querystring
      })

      # wait for async search task to complete
      view
      |> TestUtils.wait_for_render("#logs-list-container li[data-event-id]")

      html = view |> element("#logs-list-container") |> render()
      assert html =~ "some event message"
    end

    test "date picker adjusts chart display interval", %{conn: conn, source: source} do
      query = "t:2025-08-01T00:00:00..2025-08-02T00:00:00"

      {:ok, view, _html} =
        live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id, tailing?: false))

      # Increasing the chart period
      assert view
             |> has_element?("#search_chart_period option[selected]", "minute")

      render_change(view, :datetime_update, %{
        "querystring" => query
      })

      assert view
             |> has_element?("#search_chart_period option[selected]", "hour")

      # Reducing the chart period
      render_change(view, :datetime_update, %{
        "querystring" => "t:last@15m"
      })

      assert view
             |> has_element?("#search_chart_period option[selected]", "second")

      # a chart period selected by the user is preserved, and search halted
      render_change(view, :chart_controls_update, %{
        "chart_aggregate" => "count",
        "chart_period" => "day"
      })

      assert view
             |> has_element?(".alert", "Search halted")

      rendered = view |> render()

      assert rendered =~ "t%3Alast%4015minute"
      assert rendered =~ "c%3Acount%28%2A%29"
      assert rendered =~ "c%3Agroup_by%28t%3A%3Asecond%29"
      assert rendered =~ "tailing%3F=false"
      assert rendered =~ "Set chart period to second</a>"
    end

    test "log event links", %{conn: conn, source: source} do
      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, _opts ->
        {:ok,
         TestUtils.gen_bq_response(%{
           "event_message" => "some modal message",
           "testing" => "modal123",
           "id" => "some-uuid"
         })}
      end)

      {:ok, view, _html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source.id))

      # wait for async search task to complete
      view
      |> TestUtils.wait_for_render("#logs-list li[data-event-id] a[href^='/sources']")

      assert view
             |> element("#logs-list li[data-event-id] a[href^='/sources']", "permalink")
             |> render() =~ ~r/timestamp=\d{4}-\d{2}-\d{2}/

      link =
        view
        |> element(
          "#logs-list li[data-event-id] a[phx-value-log-event-id='some-uuid']",
          "view"
        )
        |> render()

      assert link =~ ~r/phx-value-log-event-timestamp="\d+/
    end

    @tag source_schema:
           %TS{
             fields: [
               %TFS{
                 name: "metadata",
                 type: "RECORD",
                 mode: "REPEATED",
                 fields: [
                   %TFS{name: "deployment_time", type: "TIMESTAMP", mode: "NULLABLE"},
                   %TFS{name: "release_time", type: "TIMESTAMP", mode: "NULLABLE"}
                 ]
               }
             ]
           }
           |> then(&SchemaBuilder.build_table_schema(%{"user_id" => "string"}, &1))
    test "log event selected fields", %{conn: conn, source: source} do
      response_schema =
        TestUtils.build_bq_schema(%{
          "event_message" => "string",
          "testing" => "string",
          "user_id" => "string",
          "id" => "string"
        })

      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, _opts ->
        {:ok,
         TestUtils.gen_bq_response(
           %{
             "event_message" => "some event message",
             "testing" => "modal123",
             "user_id" => "user-abc-123",
             "id" => "some-uuid"
           },
           response_schema
         )}
      end)

      {:ok, view, _html} =
        live_with_redirect(
          conn,
          ~p"/sources/#{source.id}/search?#{%{querystring: "s:user.id"}}"
        )

      view
      |> TestUtils.wait_for_render("#logs-list")

      assert view |> element("#logs-list-container") |> render() =~
               "some event message"

      html = view |> element("#logs-list-container #log-some-uuid-selected-fields") |> render()
      assert html =~ "id"
      assert html =~ "user-abc-123"
    end

    test "log event modal", %{conn: conn, user: user} do
      schema =
        %TS{
          fields: [
            %TFS{name: "deployment_time", type: "TIMESTAMP", mode: "NULLABLE"}
          ]
        }
        |> then(
          &SchemaBuilder.build_table_schema(%{"query" => "string", "testing" => "string"}, &1)
        )

      response_schema =
        %TS{
          fields: [
            %TFS{name: "deployment_time", type: "TIMESTAMP"}
          ]
        }
        |> then(
          &SchemaBuilder.build_table_schema(%{"query" => "string", "testing" => "string"}, &1)
        )

      respone_body = %{
        "event_message" => "some modal message",
        "testing" => "modal123",
        "query" => "SELECT\\n1",
        "deployment_time" => TestUtils.gen_bq_timestamp(~U[2026-04-27 04:22:46.765189Z]),
        "id" => "some-uuid"
      }

      {:ok, _user} =
        Logflare.Users.update_user_with_preferences(user, %{
          preferences: %{timezone: "Australia/Brisbane"}
        })

      source = insert(:source, user: user)

      insert(:source_schema,
        source: source,
        bigquery_schema: schema
      )

      # TODO: use expect, remove UDFs creation query
      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, _opts ->
        {:ok, TestUtils.gen_bq_response(respone_body, response_schema)}
      end)

      {:ok, view, _html} =
        live_with_redirect(
          conn,
          ~p"/sources/#{source.id}/search?#{%{querystring: "testing:modal123", tz: "Australia/Brisbane"}}"
        )

      # wait for async search task to complete
      view
      |> TestUtils.wait_for_render("li[data-event-id] a[phx-value-log-event-id='some-uuid']")

      pid = self()

      expect(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, opts ->
        query = opts[:body].query
        send(pid, {:query, query})

        {:ok, TestUtils.gen_bq_response(respone_body, response_schema)}
      end)

      TestUtils.retry_assert(fn ->
        view
        |> element("li[data-event-id] a[phx-value-log-event-id='some-uuid']", "view")
        |> render_click()
      end)

      TestUtils.retry_assert(fn ->
        html = render(view)

        assert html
               |> Floki.parse_document!()
               |> Floki.find("#metadata-raw-json-code")
               |> Floki.text() =~ "SELECT\\\\n1"

        assert html =~ "Raw JSON"
        assert html =~ "modal123"
        assert html =~ "some modal message"
        assert html =~ "SELECT\n1"
        assert html =~ "deployment_time"
        assert html =~ "1777263766765189"
        assert html =~ "2026-04-27 14:22:46"
        assert html =~ ~s(title="2026-04-27T04:22:46Z")
      end)

      assert_receive {:query, query}
      # filter on the field name
      assert query =~ ~r"..\.testing"
    end

    test "log event modal - inspect link", %{conn: conn, user: user} do
      schema = TestUtils.build_bq_schema(%{"testing" => "string"})
      source = insert(:source, user: user)
      insert(:source_schema, source: source, bigquery_schema: schema)

      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, _opts ->
        {:ok,
         TestUtils.gen_bq_response(%{
           "event_message" => "some modal message",
           "testing" => "modal123",
           "id" => "some-uuid"
         })}
      end)

      {:ok, view, _html} =
        live_with_redirect(
          conn,
          ~p"/sources/#{source.id}/search?#{%{querystring: "testing:modal123"}}"
        )

      view
      |> TestUtils.wait_for_render("li[data-event-id] a[phx-value-log-event-id='some-uuid']")

      view
      |> element("li[data-event-id] a[phx-value-log-event-id='some-uuid']", "view")
      |> render_click()

      TestUtils.retry_assert(fn ->
        assert render(view) =~ "inspect"
      end)

      view
      |> element("#log-event-viewer a", "inspect")
      |> render_click()

      to = assert_patch(view)

      assert to =~ ~r|^/sources/#{source.id}/search\?querystring=|
      assert to =~ "tailing%3F=false"
      refute has_element?(view, "#log-event-viewer")
    end

    test "log event modal - quick filter button appends filter to search", %{
      conn: conn,
      source: source
    } do
      stub(GoogleApi.BigQuery.V2.Api.Jobs, :bigquery_jobs_query, fn _conn, _proj_id, _opts ->
        {:ok,
         TestUtils.gen_bq_response(%{
           "event_message" => "quick filter test",
           "user_id" => "abc-123",
           "id" => "qf-uuid"
         })}
      end)

      {:ok, view, _html} =
        live_with_redirect(
          conn,
          ~p"/sources/#{source.id}/search?#{%{querystring: ~s|user_id:~\"abc\"|, tz: "Africa/Lagos"}}"
        )

      view
      |> TestUtils.wait_for_render("#logs-list-container li[data-event-id]")

      view
      |> element("li[data-event-id] a[phx-value-log-event-id='qf-uuid']", "view")
      |> render_click()

      TestUtils.retry_assert(fn ->
        html = render(view)
        assert html =~ "quick filter test"
        assert html =~ ~s|title="Append to query"|
      end)

      view
      |> element(~s|#log-event-tree-qf-uuid--user_id a[title="Append to query"]|)
      |> render_click()

      to = assert_patch(view)
      querystring = find_querystring(render(view))

      assert querystring =~ ~s|user_id:~"abc"|
      assert querystring =~ ~s|user_id:"abc-123"|

      %URI{query: query} = URI.parse(to)

      assert %{"tailing?" => "false", "tz" => "Africa/Lagos"} =
               query |> URI.decode_query() |> Map.take(["tailing?", "tz"])
    end

    test "shows flash error for malformed query", %{conn: conn, source: source} do
      assert {:ok, view, _html} =
               live_with_redirect(
                 conn,
                 Routes.live_path(conn, SearchLV, source, querystring: "t:20022")
               )

      assert render(view) =~ "Error while parsing timestamp filter"
    end

    test "shows flash error for query exceeding processed bytes limit", %{
      conn: conn,
      source: source
    } do
      assert {:ok, view, _html} =
               live_with_redirect(
                 conn,
                 Routes.live_path(conn, SearchLV, source, querystring: "t:20022")
               )

      message =
        "Query exceeded limit for bytes billed: 2000000000. 20004857600 or higher required."

      send_query_error(
        view,
        backend: BigQueryAdaptor,
        raw_error: %{
          "message" => message,
          "reason" => "billingTierLimitExceeded"
        }
      )

      assert render(view) =~
               "Query halted: total bytes processed for this query is expected to be greater than 2 GB"
    end

    test "shows user-facing error for backend missing field errors", %{
      conn: conn,
      source: source
    } do
      assert {:ok, view, _html} =
               live_with_redirect(
                 conn,
                 Routes.live_path(conn, SearchLV, source, querystring: "t:20022")
               )

      message = "Unrecognized name: notthere at [1:8]"

      send_query_error(
        view,
        backend: BigQueryAdaptor,
        raw_error: %{"message" => message}
      )

      assert render(view) =~
               "Query halted: Field &quot;notthere&quot; does not exist."
    end

    test "shows user-facing error for BigQuery nested missing field errors", %{
      conn: conn,
      source: source
    } do
      assert {:ok, view, _html} =
               live_with_redirect(
                 conn,
                 Routes.live_path(conn, SearchLV, source, querystring: "t:20022")
               )

      message = "Field name nonexistent does not exist in STRUCT<level STRING> at [1:42]"

      send_query_error(
        view,
        backend: BigQueryAdaptor,
        raw_error: %{"message" => message}
      )

      assert render(view) =~
               "Query halted: Field &quot;nonexistent&quot; does not exist."
    end

    test "shows user-facing error for ClickHouse missing field errors", %{
      conn: conn,
      source: source
    } do
      assert {:ok, view, _html} =
               live_with_redirect(
                 conn,
                 Routes.live_path(conn, SearchLV, source, querystring: "t:20022")
               )

      message =
        "Code: 47. DB::Exception: Unknown expression identifier `notthere` in scope SELECT notthere. (UNKNOWN_IDENTIFIER) (version 26.2.19.43 (official build))\n"

      send_query_error(
        view,
        backend: ClickHouseAdaptor,
        raw_error: %Ch.Error{message: message}
      )

      assert render(view) =~
               "Query halted: Field &quot;notthere&quot; does not exist."
    end

    test "shows user-facing error for Postgres missing field errors", %{
      conn: conn,
      source: source
    } do
      assert {:ok, view, _html} =
               live_with_redirect(
                 conn,
                 Routes.live_path(conn, SearchLV, source, querystring: "t:20022")
               )

      send_query_error(
        view,
        backend: PostgresAdaptor,
        raw_error: %Postgrex.Error{message: ~s|column "notthere" does not exist|}
      )

      assert render(view) =~
               "Query halted: Field &quot;notthere&quot; does not exist."
    end

    test "shows timeout specific error for query timeouts", %{
      conn: conn,
      source: source
    } do
      assert {:ok, view, _html} =
               live_with_redirect(
                 conn,
                 Routes.live_path(conn, SearchLV, source, querystring: "t:20022")
               )

      message = "Job execution was cancelled: Job timed out"

      send_query_error(
        view,
        kind: :timeout,
        backend: BigQueryAdaptor,
        raw_error: %{
          "code" => 499,
          "errors" => [%{"domain" => "global", "message" => message, "reason" => "stopped"}],
          "message" => message,
          "status" => "CANCELLED"
        }
      )

      html = render(view)

      assert html =~ "Query timed out:"
      assert html =~ "restricting the timestamp range"
      assert html =~ "adding more filtering"
      refute html =~ "Query halted:"
      refute html =~ "Backend error!"
    end

    test "shows generic backend error for unclassified query errors", %{
      conn: conn,
      source: source
    } do
      assert {:ok, view, _html} =
               live_with_redirect(
                 conn,
                 Routes.live_path(conn, SearchLV, source, querystring: "t:20022")
               )

      send_query_error(
        view,
        backend: BigQueryAdaptor,
        raw_error: %RuntimeError{message: "raw backend syntax error"},
        description: nil
      )

      assert render(view) =~
               "Backend error! Retry your query. Please contact support if this continues."
    end

    test "redirected for non-owner user", %{conn: conn, source: source} do
      non_owner_user = insert(:user)
      non_owner_team = insert(:team, user: non_owner_user)

      conn =
        conn
        |> login_user(non_owner_user)
        |> get(Routes.live_path(conn, SearchLV, source, t: non_owner_team.id))

      assert html_response(conn, 404) =~ "not found"
    end

    test "redirected for anonymous user", %{conn: conn, source: source} do
      conn =
        conn
        |> Map.update!(:private, &Map.drop(&1, [:plug_session]))
        |> Plug.Test.init_test_session(%{})
        |> assign(:user, nil)
        |> get(Routes.live_path(conn, SearchLV, source))

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "must be logged in"
      assert html_response(conn, 302)
      assert redirected_to(conn) == "/auth/login"
    end

    test "stop/start live search", %{conn: conn, source: source} do
      {:ok, view, _html} = live_with_redirect(conn, Routes.live_path(conn, SearchLV, source))

      # post-init fetching
      view
      |> TestUtils.wait_for_render("#logs-list-container li[data-event-id]")

      assert get_view_assigns(view).tailing?
      render_click(view, "soft_pause", %{})

      # Allow database access after pause click which might trigger a new search

      refute get_view_assigns(view).tailing?

      render_click(view, "soft_play", %{})

      assert get_view_assigns(view).tailing?
    end

    test "opening a log event pauses a live search", %{conn: conn, source: source} do
      {:ok, view, _html} = live_with_redirect(conn, ~p"/sources/#{source.id}/search")

      view |> TestUtils.wait_for_render("#logs-list li:first-of-type a")
      assert get_view_assigns(view).tailing?

      view
      |> element("#logs-list li:first-of-type a", "view")
      |> render_click()

      refute get_view_assigns(view).tailing?

      render_click(view, "close_log_event_modal", %{})

      assert get_view_assigns(view).tailing?
    end

    test "closing context does not resume a paused search", %{
      conn: conn,
      source: source
    } do
      {:ok, view, _html} = live_with_redirect(conn, ~p"/sources/#{source.id}/search")

      view |> TestUtils.wait_for_render("#logs-list li[data-event-id] a")
      assert get_view_assigns(view).tailing?

      render_click(view, "soft_pause", %{})
      refute get_view_assigns(view).tailing?

      render_click(view, "open_log_event_modal", %{})

      render_click(view, "close_log_event_modal", %{})

      refute get_view_assigns(view).tailing?
    end

    test "closing context resumes a search that was live", %{
      conn: conn,
      source: source
    } do
      {:ok, view, _html} = live_with_redirect(conn, ~p"/sources/#{source.id}/search")

      view |> TestUtils.wait_for_render("#logs-list li[data-event-id] a")
      assert get_view_assigns(view).tailing?

      render_click(view, "open_log_event_modal", %{})

      refute get_view_assigns(view).tailing?

      render_click(view, "close_log_event_modal", %{})

      assert get_view_assigns(view).tailing?
    end

    test "datetime_update", %{conn: conn, source: source} do
      {:ok, view, _html} =
        live_with_redirect(conn, Routes.live_path(conn, SearchLV, source, querystring: "error"))

      # post-init fetching
      view
      |> TestUtils.wait_for_render("#logs-list-container")

      render_change(view, "datetime_update", %{"querystring" => "t:last@2h"})

      assert get_view_assigns(view).querystring =~ "t:last@2hour"
      assert get_view_assigns(view).querystring =~ "error"

      render_change(view, "datetime_update", %{
        "querystring" => "t:2020-04-20T00:{01..02}:00",
        "period" => "second"
      })

      assert get_view_assigns(view).querystring =~ "error"
      assert get_view_assigns(view).querystring =~ "t:2020-04-20T00:{01..02}:00"
    end
  end

  defp send_query_error(view, attrs) do
    attrs = Keyword.put_new(attrs, :kind, :invalid_query)
    error = struct!(QueryError, attrs)

    send(view.pid, {:search_error, %{error: error}})
  end

  defp get_view_assigns(view) do
    :sys.get_state(view.pid).socket.assigns
  end

  defp find_search_form_value(html, selector) do
    {:ok, document} = Floki.parse_document(html)

    document
    |> Floki.find(selector)
    |> Floki.attribute("value")
    |> hd
  end

  def find_selected_chart_period(html) do
    find_search_form_value(html, "#search_chart_period option[selected]")
  end

  def find_selected_chart_aggregate(html) do
    assert find_search_form_value(html, "#search_chart_aggregate option[selected]")
  end

  def find_chart_aggregate(html) do
    assert find_search_form_value(html, "#search_chart_aggregate option")
  end

  def find_querystring(html) do
    {:ok, document} = Floki.parse_document(html)

    document
    |> Floki.find("#lql-editor-hook")
    |> Floki.attribute("data-querystring")
    |> hd()
  end
end
