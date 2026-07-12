defmodule Tabletap.Repo.Migrations.CreateCartItemOptions do
  use Ecto.Migration

  def change do
    create table(:cart_item_options, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :cart_item_id,
          references(:cart_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      # :restrict — same archive-not-delete reasoning as cart_items.menu_item_id.
      add :option_id,
          references(:modifier_options,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cart_item_options, [:org_id])
    create index(:cart_item_options, [:cart_item_id])

    # A line can't select the same option twice.
    create unique_index(:cart_item_options, [:cart_item_id, :option_id])
  end
end
