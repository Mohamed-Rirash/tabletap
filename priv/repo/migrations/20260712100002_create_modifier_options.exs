defmodule Tabletap.Repo.Migrations.CreateModifierOptions do
  use Ecto.Migration

  def change do
    create table(:modifier_options, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :group_id,
          references(:modifier_groups,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :name, :string, null: false
      add :price_delta, :money_with_currency, null: false
      add :default, :boolean, null: false, default: false
      add :active, :boolean, null: false, default: true
      add :position, :integer, null: false, default: 0
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:modifier_options, [:org_id])
    create index(:modifier_options, [:group_id, :position])

    # Composite-FK target for Feature 08's order_item_modifiers.option_id —
    # order snapshots will reference the option row they were chosen from.
    create unique_index(:modifier_options, [:id, :org_id])
  end
end
