defmodule Tabletap.Repo.Migrations.CreateRecipeLines do
  use Ecto.Migration

  def change do
    create table(:recipe_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :menu_item_id,
          references(:menu_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :ingredient_id,
          references(:ingredients,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :qty_per_serving, :decimal, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:recipe_lines, [:org_id])
    create index(:recipe_lines, [:menu_item_id])
    create unique_index(:recipe_lines, [:menu_item_id, :ingredient_id])
  end
end
