defmodule Tabletap.Repo.Migrations.CreateCartItems do
  use Ecto.Migration

  def change do
    create table(:cart_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :cart_id,
          references(:carts, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      # :restrict, not :delete_all — same reasoning as menu_items.category_id:
      # a menu item any cart line ever referenced counts as "has history"
      # under the archive-not-delete rule (code-standards.md).
      add :menu_item_id,
          references(:menu_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :qty, :integer, null: false, default: 1
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:cart_items, [:org_id])
    create index(:cart_items, [:cart_id])

    # Composite-FK target for cart_item_options.
    create unique_index(:cart_items, [:id, :org_id])
  end
end
