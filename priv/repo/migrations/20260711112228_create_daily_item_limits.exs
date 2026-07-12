defmodule Tabletap.Repo.Migrations.CreateDailyItemLimits do
  use Ecto.Migration

  def change do
    create table(:daily_item_limits, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :item_id,
          references(:menu_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      # Business date (Tenants.business_date/2), not the calendar date —
      # CONTEXT.md "Business day / cutoff".
      add :date, :date, null: false
      add :limit_qty, :integer, null: false
      add :sold_qty, :integer, null: false, default: 0
      add :reserved_qty, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:daily_item_limits, [:org_id])
    create index(:daily_item_limits, [:venue_id, :date])

    # One limit row per item per business day — Catalog.set_daily_limit/4
    # upserts on this.
    create unique_index(:daily_item_limits, [:item_id, :date])
  end
end
