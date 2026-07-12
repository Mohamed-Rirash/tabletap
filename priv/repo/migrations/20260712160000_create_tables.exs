defmodule Tabletap.Repo.Migrations.CreateTables do
  use Ecto.Migration

  def change do
    create table(:tables, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      # Free-form so venues can name tables "12", "A3", or "Patio 1"
      # (label is a separate optional description).
      add :number, :string, null: false
      add :label, :string
      add :qr_token, :string, null: false
      add :active, :boolean, null: false, default: true
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:tables, [:org_id])

    # The QR encodes /t/:qr_token — globally unique, opaque, rotatable.
    create unique_index(:tables, [:qr_token])

    # Two live tables can't share a number in the same venue; archived
    # rows are excluded so an archived "12" doesn't block a new "12".
    create unique_index(:tables, [:venue_id, :number],
             where: "archived_at IS NULL",
             name: :tables_venue_number_index
           )

    # Composite-FK target for orders.table_id (Feature 08) — same
    # (id, org_id) pattern as venues/menu_categories.
    create unique_index(:tables, [:id, :org_id])
  end
end
