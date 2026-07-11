defmodule Tabletap.Repo.Migrations.CreateVenues do
  use Ecto.Migration

  def change do
    create table(:venues, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :currency, :string, null: false
      add :timezone, :string, null: false
      add :locale, :string, null: false, default: "so"
      add :business_day_cutoff, :time, null: false, default: "04:00:00"
      add :fulfillment_mode, :string, null: false, default: "waiter"
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:venues, [:org_id])
    create unique_index(:venues, [:org_id, :slug])

    # Composite-FK target for memberships/staff_invites/tables/... — every
    # child table's (venue_id, org_id) FK is validated against this by
    # Postgres, so a row can never point at another tenant's venue
    # (code-standards.md "Composite FKs"; library-docs.md Repo pattern).
    create unique_index(:venues, [:id, :org_id])
  end
end
