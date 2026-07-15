defmodule Tabletap.Repo.Migrations.AddIngredientDeltasToModifierOptions do
  use Ecto.Migration

  def change do
    # architecture.md Data Model's `ingredient_id`/`ingredient_qty_delta`
    # columns — deferred since Feature 05 (no `ingredients` table existed
    # yet); land now that build-plan.md Feature 12 owns them. Nullable:
    # most options have no stock effect at all (e.g. "No onions" removes
    # nothing from the ledger — the recipe's base quantity already
    # assumed the item is served as photographed).
    alter table(:modifier_options) do
      add :ingredient_id,
          references(:ingredients,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :nilify_all
          )

      add :ingredient_qty_delta, :decimal
    end

    create index(:modifier_options, [:ingredient_id])
  end
end
