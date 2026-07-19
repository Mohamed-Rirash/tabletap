defmodule Tabletap.Feedback.ItemRating do
  @moduledoc """
  One customer's rating of one served order line (architecture.md Data
  Model; build-plan.md Feature 17). `order_item_id` is unique — "one
  rating per served order item" is a hard invariant, enforced at the DB
  layer, not just in `Tabletap.Feedback.rate_item/5`'s own check.

  `customer_user_id` is nullable: the tracker never requires an account
  to rate, same zero-login philosophy as ordering itself (a rating from
  a guest still counts). `menu_item_id` rides along even though it's
  reachable via `order_item.menu_item_id` — every read here is "ratings
  for this menu item," and a menu item is never deleted once ordered
  (Q41), so denormalizing it avoids a join on the one query this schema
  exists to serve.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "item_ratings" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :order_item, Tabletap.Ordering.OrderItem
    belongs_to :menu_item, Tabletap.Catalog.MenuItem
    belongs_to :customer_user, Tabletap.Accounts.User, foreign_key: :customer_user_id

    field :stars, :integer
    field :comment, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def new_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :org_id,
      :venue_id,
      :order_item_id,
      :menu_item_id,
      :customer_user_id,
      :stars,
      :comment
    ])
    |> validate_required([:org_id, :venue_id, :order_item_id, :menu_item_id, :stars])
    |> validate_inclusion(:stars, 1..5)
    |> validate_length(:comment, max: 2000)
    |> unique_constraint(:order_item_id)
  end
end
