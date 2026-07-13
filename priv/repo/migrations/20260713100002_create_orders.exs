defmodule Tabletap.Repo.Migrations.CreateOrders do
  use Ecto.Migration

  def change do
    create table(:orders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      # Nullable — takeaway orders have no table (mirrors carts.table_id).
      add :table_id,
          references(:tables, type: :binary_id, with: [org_id: :org_id], on_delete: :nilify_all)

      add :guest_token, :string, null: false
      add :number, :integer, null: false
      # Stored, not re-derived from placed_at + cutoff on every read — same
      # reasoning as daily_item_limits.date (Tenants.business_date/2 is
      # only computed once, at checkout).
      add :business_date, :date, null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "pending_payment"

      add :placed_at, :utc_datetime
      add :accepted_at, :utc_datetime
      add :ready_at, :utc_datetime
      add :served_at, :utc_datetime
      add :closed_at, :utc_datetime

      add :subtotal, :money_with_currency, null: false
      add :discount_total, :money_with_currency, null: false
      add :total, :money_with_currency, null: false
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:orders, [:org_id])
    create index(:orders, [:venue_id])
    create index(:orders, [:guest_token, :venue_id])

    # The order-number sequence's own uniqueness guarantee (defense in
    # depth — order_number_counters is what actually makes assignment
    # atomic; this is what makes a violation impossible to persist).
    create unique_index(:orders, [:venue_id, :business_date, :number])

    # The 12-min TTL sweep's query shape (design-qa.md Q1).
    create index(:orders, [:status, :inserted_at])

    # Composite-FK target for order_items.
    create unique_index(:orders, [:id, :org_id])
  end
end
