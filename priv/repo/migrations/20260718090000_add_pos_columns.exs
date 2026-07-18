defmodule Tabletap.Repo.Migrations.AddPosColumns do
  use Ecto.Migration

  def change do
    # design-qa.md Q3 — the venue-level toggle for "customer pays cash at
    # the counter" on the QR checkout. Off by default; venues that don't
    # want counter traffic never see the option (architecture.md's
    # documented field name for this row).
    alter table(:venues) do
      add :pay_at_counter_enabled, :boolean, null: false, default: false
    end

    # architecture.md's own data-model row for orders.placed_by_membership_id
    # — deferred since Feature 08's own moduledoc, lands now with its first
    # real caller (a cashier placing an order on a customer's behalf).
    # :nilify_all — a deactivated cashier's history should keep the order,
    # not lose it (membership deactivation never rewrites past attribution).
    alter table(:orders) do
      add :placed_by_membership_id,
          references(:memberships,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :nilify_all
          )
    end

    create index(:orders, [:placed_by_membership_id])

    # architecture.md's own data-model row for payments.cashier_membership_id
    # — who took a cash payment (recorded by cashier POS, Q22/Q3).
    alter table(:payments) do
      add :cashier_membership_id,
          references(:memberships,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :nilify_all
          )
    end

    create index(:payments, [:cashier_membership_id])
  end
end
