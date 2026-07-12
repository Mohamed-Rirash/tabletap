defmodule Tabletap.Repo.Migrations.AddIngredientsToMenuItems do
  use Ecto.Migration

  def change do
    # Descriptive-only ("beef patty, brioche bun, cheddar") — not the
    # structured ingredient/recipe/stock-deduction system, which is a
    # separate table pair (`ingredients` + `recipe_lines`) landing in
    # Feature 12 with its own BOM and stock effects.
    alter table(:menu_items) do
      add :ingredients, :text
    end
  end
end
