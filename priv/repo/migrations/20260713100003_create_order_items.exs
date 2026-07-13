defmodule Tabletap.Repo.Migrations.CreateOrderItems do
  use Ecto.Migration

  def change do
    create table(:order_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :order_id,
          references(:orders, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      # :restrict — same archive-not-delete reasoning as cart_items: a menu
      # item any order line ever referenced has history under the
      # never-hard-delete-with-references rule (code-standards.md).
      add :menu_item_id,
          references(:menu_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      # Snapshots — survive later menu edits (architecture.md).
      add :name_snapshot, :string, null: false
      add :unit_price_snapshot, :money_with_currency, null: false
      add :qty, :integer, null: false
      add :line_total, :money_with_currency, null: false
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:order_items, [:org_id])
    create index(:order_items, [:order_id])

    # Composite-FK target for order_item_modifiers.
    create unique_index(:order_items, [:id, :org_id])
  end
end
