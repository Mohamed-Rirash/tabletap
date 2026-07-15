defmodule Tabletap.Inventory.StockMovement do
  @moduledoc """
  One append-only ledger row (architecture.md Data Model) — the source of
  truth `Ingredient.stock_qty` caches. `:sale` rows are written by
  `Inventory.deduct_for_order/2` on every `served` transition
  (build-plan.md Feature 11); `:restock`/`:wastage`/`:adjustment` land
  with Feature 13's stock-ops flows.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @reasons [:restock, :sale, :wastage, :adjustment]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stock_movements" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :ingredient, Tabletap.Inventory.Ingredient
    belongs_to :order, Tabletap.Ordering.Order
    belongs_to :staff_user, Tabletap.Accounts.User, foreign_key: :staff_user_id

    field :qty_delta, :decimal
    field :reason, Ecto.Enum, values: @reasons
    field :unit_cost, Money.Ecto.Composite.Type
    field :note, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def reasons, do: @reasons

  @doc "A `:sale` deduction row — always programmatically built, never cast from user input."
  def deduction_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:org_id, :venue_id, :ingredient_id, :order_id, :qty_delta])
    |> validate_required([:org_id, :venue_id, :ingredient_id, :qty_delta])
    |> put_change(:reason, :sale)
  end

  @doc """
  A `:restock`/`:wastage`/`:adjustment` row (build-plan.md Feature 13).
  Amounts are always pre-parsed by `Inventory.UnitInput` before reaching
  here — this changeset validates the ledger row itself, not raw text.
  `:restock`'s reason is self-evident from `unit_cost`; `:wastage`/
  `:adjustment` always require a `note` (code-standards.md "manual order
  edits always record who did it" — same discipline for stock).
  """
  def movement_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :org_id,
      :venue_id,
      :ingredient_id,
      :order_id,
      :staff_user_id,
      :qty_delta,
      :reason,
      :unit_cost,
      :note
    ])
    |> validate_required([:org_id, :venue_id, :ingredient_id, :reason, :qty_delta])
    |> validate_inclusion(:reason, @reasons)
    |> validate_number(:qty_delta, not_equal_to: 0)
    |> validate_note_required_for_reason()
  end

  defp validate_note_required_for_reason(changeset) do
    if get_field(changeset, :reason) in [:adjustment, :wastage] do
      validate_required(changeset, [:note])
    else
      changeset
    end
  end
end
