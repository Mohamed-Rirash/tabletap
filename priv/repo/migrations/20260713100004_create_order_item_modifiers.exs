defmodule Tabletap.Repo.Migrations.CreateOrderItemModifiers do
  use Ecto.Migration

  def change do
    create table(:order_item_modifiers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :order_item_id,
          references(:order_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      # :restrict — same reasoning as order_items.menu_item_id.
      add :option_id,
          references(:modifier_options,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :name_snapshot, :string, null: false
      add :price_delta_snapshot, :money_with_currency, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:order_item_modifiers, [:org_id])
    create index(:order_item_modifiers, [:order_item_id])
  end
end
