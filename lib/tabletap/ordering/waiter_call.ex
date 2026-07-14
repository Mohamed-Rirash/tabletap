defmodule Tabletap.Ordering.WaiterCall do
  @moduledoc """
  A "call waiter" button tap (architecture.md Data Model; build-plan.md
  Feature 10). Never created for a pickup-mode venue (design-qa.md Q46 —
  the tracker shows "Ask at the counter" instead of a call button there).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:open, :acknowledged, :resolved]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "waiter_calls" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :table, Tabletap.Tenants.Table
    belongs_to :order, Tabletap.Ordering.Order

    field :status, Ecto.Enum, values: @statuses, default: :open

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def statuses, do: @statuses

  def new_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:org_id, :venue_id, :table_id, :order_id, :status])
    |> validate_required([:org_id, :venue_id, :table_id, :order_id])
  end
end
