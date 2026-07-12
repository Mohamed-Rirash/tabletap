defmodule Tabletap.Repo.Migrations.CreateCarts do
  use Ecto.Migration

  def change do
    create table(:carts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      # Nullable — takeaway carts have no table. :nilify_all not :restrict:
      # tables are archive-not-delete (never actually hard-deleted while
      # referenced), so this only matters in theory.
      add :table_id,
          references(:tables, type: :binary_id, with: [org_id: :org_id], on_delete: :nilify_all)

      add :guest_token, :string, null: false
      add :kind, :string, null: false, default: "dine_in"
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create index(:carts, [:org_id])
    create index(:carts, [:venue_id])

    # One active cart per guest_token+venue (architecture.md); past
    # converted/abandoned carts for the same guest+venue are fine to keep.
    create unique_index(:carts, [:guest_token, :venue_id],
             where: "status = 'active'",
             name: :carts_active_guest_token_venue_id_index
           )

    # The abandoned-cart sweep's own query shape: active carts stale since X.
    create index(:carts, [:status, :updated_at])

    # Composite-FK target for cart_items (and Feature 08's orders.cart_id).
    create unique_index(:carts, [:id, :org_id])
  end
end
