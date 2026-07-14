defmodule Tabletap.Repo.Migrations.AddWaiterAssignmentToOrders do
  use Ecto.Migration

  def change do
    alter table(:orders) do
      # build-plan.md Feature 10 — deferred at Order's own creation
      # (architecture.md's data-model row already documented this field;
      # Feature 08 had no assignment algorithm yet to populate it).
      add :waiter_membership_id,
          references(:memberships,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :nilify_all
          )

      # design-qa.md Q9 (waiter "Can't find customer") and Q32 (pickup
      # no-show) are the same shape: an order needs a human to resolve
      # it. One shared flag rather than two near-identical booleans —
      # nil means nothing is wrong.
      add :flag, :string
      add :flagged_at, :utc_datetime
    end

    create index(:orders, [:waiter_membership_id])
    # The claim board's and the assignment algorithm's query shape:
    # every placed/accepted/preparing order at a venue, by waiter.
    create index(:orders, [:venue_id, :status, :waiter_membership_id])
  end
end
