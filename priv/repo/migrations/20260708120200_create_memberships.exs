defmodule Tabletap.Repo.Migrations.CreateMemberships do
  use Ecto.Migration

  def change do
    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      # Owner rows have venue_id: nil (org-wide) — architecture.md.
      add :venue_id,
          references(:venues,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          )

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:memberships, [:org_id])
    create index(:memberships, [:user_id])
    create index(:memberships, [:venue_id])

    create unique_index(:memberships, [:org_id, :venue_id, :user_id],
             name: :memberships_org_venue_user_index
           )
  end
end
