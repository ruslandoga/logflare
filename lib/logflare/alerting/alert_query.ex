defmodule Logflare.Alerting.AlertQuery do
  @moduledoc false
  use TypedEctoSchema

  import Ecto.Changeset

  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler
  alias Logflare.Alerting.Promql
  alias Logflare.Endpoints.EndpointQuery

  @derive {Jason.Encoder,
           only: [
             :id,
             :token,
             :cron,
             :name,
             :description,
             :language,
             :query,
             :query_backend_id,
             :evaluation_delay_seconds,
             :webhook_notification_url,
             :slack_hook_url,
             :enabled,
             :backends
           ]}
  typed_schema "alert_queries" do
    field :name, :string
    field :description, :string
    field :language, Ecto.Enum, values: [:bq_sql, :pg_sql, :lql, :promql], default: :bq_sql
    field :query, :string
    field :cron, :string
    field :source_mapping, :map
    field :evaluation_delay_seconds, :integer, default: 30
    field :token, Ecto.UUID, autogenerate: true
    field :slack_hook_url, :string
    field :webhook_notification_url, :string
    field :enabled, :boolean, default: true

    belongs_to :user, Logflare.User
    belongs_to :query_backend, Logflare.Backends.Backend

    many_to_many :backends, Logflare.Backends.Backend,
      join_through: "alert_queries_backends",
      on_replace: :delete

    timestamps()
  end

  @doc false
  @spec changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def changeset(alert_query, attrs, opts \\ []) do
    alert_query
    |> cast(attrs, [
      :name,
      :description,
      :language,
      :query,
      :query_backend_id,
      :evaluation_delay_seconds,
      :cron,
      :slack_hook_url,
      :webhook_notification_url,
      :enabled
    ])
    |> validate_required([:name, :query, :cron, :language, :evaluation_delay_seconds])
    |> validate_number(:evaluation_delay_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 86_400
    )
    |> foreign_key_constraint(:query_backend_id)
    |> validate_change(:cron, fn :cron, cron ->
      with {:ok, expr} <- CronParser.parse(cron),
           [first, second] <- Scheduler.get_next_run_dates(expr) |> Enum.take(2),
           true <- NaiveDateTime.diff(first, second, :minute) <= -5 do
        []
      else
        [] -> [cron: "not enough run dates"]
        false -> [cron: "can only trigger up to 5 minute intervals"]
        {:error, msg} -> [cron: msg]
      end
    end)
    |> configure_query_language(opts)
  end

  defp configure_query_language(changeset, opts) do
    if get_field(changeset, :language) == :promql do
      changeset
      |> put_change(:source_mapping, nil)
      |> validate_required([:query_backend_id])
      |> validate_query_backend(opts)
    else
      changeset = put_change(changeset, :query_backend_id, nil)

      changeset =
        if changed?(changeset, :language) do
          changeset
          |> put_change(:source_mapping, nil)
          |> force_change(:query, get_field(changeset, :query))
        else
          changeset
        end

      EndpointQuery.update_source_mapping(changeset)
    end
  end

  defp validate_query_backend(%{valid?: true} = changeset, opts) do
    owner_id =
      case get_field(changeset, :user) do
        %{id: id} -> get_field(changeset, :user_id) || id
        _ -> get_field(changeset, :user_id)
      end

    if disabling?(changeset) do
      changeset
    else
      case Promql.fetch_backend(owner_id, get_field(changeset, :query_backend_id), opts) do
        {:ok, _backend} -> changeset
        {:error, message} -> add_error(changeset, :query_backend_id, message)
      end
    end
  end

  defp validate_query_backend(changeset, _opts), do: changeset

  defp disabling?(changeset) do
    not is_nil(changeset.data.id) and get_change(changeset, :enabled) == false and
      Enum.all?(changeset.changes, fn {field, _value} -> field in [:enabled, :source_mapping] end) and
      not Map.has_key?(changeset.params, "backends") and
      not Map.has_key?(changeset.params, "backend_ids")
  end
end
