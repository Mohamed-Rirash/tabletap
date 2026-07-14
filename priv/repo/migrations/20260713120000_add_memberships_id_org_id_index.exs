defmodule Tabletap.Repo.Migrations.AddMembershipsIdOrgIdIndex do
  use Ecto.Migration

  def change do
    # Composite-FK target for shifts.membership_id / orders.waiter_membership_id
    # (build-plan.md Feature 10) — same pattern every other composite-FK
    # parent table already has (orders, payments, ...).
    create unique_index(:memberships, [:id, :org_id])
  end
end
