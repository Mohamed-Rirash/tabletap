defmodule Tabletap.Repo.Migrations.AddCustomerUserId do
  use Ecto.Migration

  def change do
    # architecture.md's own data-model row for orders.customer_user_id —
    # deferred since Feature 08's own moduledoc, lands now with Feature
    # 16's real caller (post-order magic-link signup, /me/history).
    # `carts.customer_user_id` (also in architecture.md's data model)
    # stays deferred — Feature 16 has no caller for it either; a cart is
    # ephemeral pre-checkout state, no cross-venue history reads it.
    # Not a composite (id, org_id) FK: `users` isn't a tenant-owned table
    # (architecture.md "Customer data is NOT tenant-owned"), so this is a
    # plain single-column reference, same shape as
    # `stock_movements.staff_user_id`. :nilify_all — design-qa.md Q15 GDPR
    # deletion: "orders anonymized (customer_user_id nulled, guest linkage
    # severed) but retained."
    alter table(:orders) do
      add :customer_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:orders, [:customer_user_id])

    # No new index needed for the cross-venue linking write
    # (Ordering.link_guest_orders_to_customer/2, guest_token-only WHERE) —
    # the existing composite index(:orders, [:guest_token, :venue_id]) from
    # Feature 08 already serves an equality filter on its leading column.
  end
end
