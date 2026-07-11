defmodule Tabletap.Repo.Migrations.CreateStaffInvites do
  use Ecto.Migration

  def change do
    create table(:staff_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :email, :string, null: false
      add :role, :string, null: false
      add :token, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:staff_invites, [:org_id])
    create index(:staff_invites, [:venue_id])
    create unique_index(:staff_invites, [:token])
  end
end
