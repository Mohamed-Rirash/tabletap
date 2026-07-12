defmodule Tabletap.Repo.Migrations.CreateItemModifierGroups do
  use Ecto.Migration

  def change do
    create table(:item_modifier_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :item_id,
          references(:menu_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :group_id,
          references(:modifier_groups,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:item_modifier_groups, [:org_id])
    create index(:item_modifier_groups, [:group_id])
    create index(:item_modifier_groups, [:item_id, :position])

    # A group attaches to an item at most once.
    create unique_index(:item_modifier_groups, [:item_id, :group_id])
  end
end
