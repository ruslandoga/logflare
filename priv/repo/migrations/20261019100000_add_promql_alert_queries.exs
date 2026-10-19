defmodule Logflare.Repo.Migrations.AddPromqlAlertQueries do
  use Ecto.Migration

  def change do
    alter table(:alert_queries) do
      add :query_backend_id, references(:backends, on_delete: :restrict)
      add :evaluation_delay_seconds, :integer, null: false, default: 30
    end

    create index(:alert_queries, [:query_backend_id])

    create constraint(:alert_queries, :alert_queries_evaluation_delay_seconds_range,
             check: "evaluation_delay_seconds BETWEEN 0 AND 86400"
           )
  end
end
