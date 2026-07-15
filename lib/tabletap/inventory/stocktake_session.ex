defmodule Tabletap.Inventory.StocktakeSession do
  @moduledoc """
  One physical-count session (build-plan.md Feature 13, design-qa.md
  Q14/Q43). Its `stocktake_lines` snapshot theoretical quantities the
  moment the session opens, so sales during the count can't move the
  number the count gets compared against — `Inventory.start_stocktake/1`
  is the only writer of that snapshot.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:open, :closed]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stocktake_sessions" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :started_by_user, Tabletap.Accounts.User, foreign_key: :started_by_user_id

    field :status, Ecto.Enum, values: @statuses, default: :open
    field :closed_at, :utc_datetime

    has_many :lines, Tabletap.Inventory.StocktakeLine, foreign_key: :session_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def new_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:org_id, :venue_id, :started_by_user_id])
    |> validate_required([:org_id, :venue_id])
  end

  def close_changeset(session) do
    change(session, status: :closed, closed_at: DateTime.utc_now(:second))
  end
end
