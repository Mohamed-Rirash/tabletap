defmodule Tabletap.Repo.Migrations.CreateShifts do
  use Ecto.Migration

  def change do
    create table(:shifts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :membership_id,
          references(:memberships,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      # Q45 — a forgotten clock-out auto-closes at the business-day
      # cutoff; flagged so the employee work report can distinguish a
      # real end-of-shift from a missed one.
      add :auto_closed, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:shifts, [:org_id])
    create index(:shifts, [:membership_id])

    # The assignment algorithm's + the auto-close sweep's query shape:
    # "does this membership have an open shift right now" / "every open
    # shift at this venue."
    create index(:shifts, [:venue_id, :ended_at])
  end
end
