defmodule Tabletap.Repo.Migrations.CreateOrgs do
  use Ecto.Migration

  def change do
    create table(:orgs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :plan, :string, null: false, default: "essentials"
      add :subscription_status, :string, null: false, default: "trialing"
      add :trial_ends_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:orgs, [:slug])
  end
end
