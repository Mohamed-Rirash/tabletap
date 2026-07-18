defmodule Tabletap.Repo.Migrations.CreateOrderDiscounts do
  use Ecto.Migration

  def change do
    # architecture.md Data Model: "org_id, order_id, order_item_id
    # (nullable = whole order), amount (money), reason, staff_membership_id
    # — Manager/cashier applied, permission-gated, always attributed."
    # design-qa.md Q36: discounts exist only pre-payment — order_discounts
    # is immutable once the order leaves pending_payment (enforced in
    # Ordering.apply_discount/4, not at the DB layer).
    create table(:order_discounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :order_id,
          references(:orders, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      # nil = whole-order discount; set = a line-level discount attributed
      # to one order_item. :delete_all — a discount has no meaning once
      # its own line is gone (order_items are never deleted post-checkout
      # in practice, but the FK shape should still be correct).
      add :order_item_id,
          references(:order_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          )

      add :amount, :money_with_currency, null: false
      add :reason, :string, null: false

      # :restrict, not :nilify_all — "always attributed" (code-standards.md)
      # is a hard requirement; memberships are deactivated, never deleted
      # (Q44), so this never actually fires in practice.
      add :staff_membership_id,
          references(:memberships,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:order_discounts, [:org_id])
    create index(:order_discounts, [:order_id])
    create index(:order_discounts, [:order_item_id])
  end
end
