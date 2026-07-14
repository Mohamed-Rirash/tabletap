defmodule Tabletap.Staffing.Shift do
  @moduledoc """
  A waiter/cashier clock-in/out window (architecture.md Data Model;
  build-plan.md Feature 10). Only an *open* shift (`ended_at: nil`) makes
  its membership a candidate for the waiter-assignment algorithm.

  Forgotten clock-outs auto-close at the venue's business-day cutoff,
  flagged `auto_closed` (design-qa.md Q45) — never silently vanish, and
  never bleed into the next business day's staffing numbers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "shifts" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :membership, Tabletap.Tenants.Membership

    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :auto_closed, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def clock_in_changeset(org_id, venue_id, membership_id) do
    %__MODULE__{}
    |> change(%{
      org_id: org_id,
      venue_id: venue_id,
      membership_id: membership_id,
      started_at: DateTime.utc_now(:second)
    })
  end

  def clock_out_changeset(shift, opts \\ []) do
    change(shift, %{
      ended_at: DateTime.utc_now(:second),
      auto_closed: Keyword.get(opts, :auto_closed, false)
    })
  end
end
