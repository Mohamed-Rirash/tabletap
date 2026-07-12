defmodule Tabletap.Ordering.Cart do
  @moduledoc """
  A guest's in-progress order for one venue (architecture.md Data Model;
  build-plan.md Feature 07). DB-backed so it survives LiveView reconnects
  and deploys (design-qa.md Q50) — the menu LiveView rebuilds it from
  here on every mount rather than holding it in socket state.

  Always live-computed, never a snapshot: `Ordering.cart_total/1` reads
  the *current* item price and option deltas every time. Prices only
  freeze once a cart converts into an order (Feature 08) — carts
  themselves must reflect today's menu, not the moment each line was
  added (code-standards.md "Snapshots over joins for history" applies to
  orders, not carts).

  `org_id`/`venue_id`/`guest_token` are set programmatically by
  `Tabletap.Ordering`, never cast from user attrs. `customer_user_id`
  (architecture.md's data model row) is deliberately not a column yet —
  no `users`-as-customers linkage exists until Feature 16, same
  deferral `Tenants.Venue` used for its Feature 09/08-only fields.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "carts" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :table, Tabletap.Tenants.Table

    field :guest_token, :string
    field :kind, Ecto.Enum, values: [:dine_in, :takeaway], default: :dine_in
    field :status, Ecto.Enum, values: [:active, :converted, :abandoned], default: :active

    has_many :items, Tabletap.Ordering.CartItem, foreign_key: :cart_id

    timestamps(type: :utc_datetime)
  end

  @doc "A fresh opaque guest identity — url-safe, unguessable."
  def generate_guest_token, do: :crypto.strong_rand_bytes(20) |> Base.url_encode64(padding: false)

  @doc "A brand-new active cart for `guest_token` at `venue_id`, optionally seated at `table_id`."
  def new_changeset(org_id, venue_id, table_id, guest_token) do
    %__MODULE__{}
    |> change(org_id: org_id, venue_id: venue_id, table_id: table_id, guest_token: guest_token)
    |> unique_constraint([:guest_token, :venue_id],
      name: :carts_active_guest_token_venue_id_index,
      message: "already has an active cart"
    )
  end

  def kind_changeset(cart, kind) when kind in [:dine_in, :takeaway] do
    change(cart, kind: kind)
  end

  def status_changeset(cart, status) when status in [:active, :converted, :abandoned] do
    change(cart, status: status)
  end
end
