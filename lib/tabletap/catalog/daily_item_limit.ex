defmodule Tabletap.Catalog.DailyItemLimit do
  @moduledoc """
  "50 rice today" (CONTEXT.md) — one row per item per business date. No
  row for a given (item, date) means unlimited, not zero. `sold_qty`/
  `reserved_qty` are Ordering's to touch at checkout time (build-plan.md
  Feature 08, architecture.md's atomic `UPDATE ... WHERE` reservation) —
  Feature 04 only ever writes `limit_qty`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "daily_item_limits" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :item, Tabletap.Catalog.MenuItem

    field :date, :date
    field :limit_qty, :integer
    field :sold_qty, :integer, default: 0
    field :reserved_qty, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def set_limit_changeset(limit, attrs) do
    limit
    |> cast(attrs, [:limit_qty])
    |> validate_required([:limit_qty])
    |> validate_number(:limit_qty, greater_than: 0)
  end

  @doc "How many are still sellable today, given what's already sold/reserved."
  def remaining(%__MODULE__{limit_qty: limit_qty, sold_qty: sold_qty, reserved_qty: reserved_qty}) do
    max(limit_qty - sold_qty - reserved_qty, 0)
  end
end
