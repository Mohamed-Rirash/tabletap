defmodule Tabletap.Staffing do
  @moduledoc """
  Shifts and waiter availability (architecture.md "staffing/"; build-plan.md
  Feature 10). The waiter-assignment algorithm (`Tabletap.Ordering`) reads
  `list_on_shift_waiter_membership_ids/1` to build its candidate pool —
  Presence (`TabletapWeb.Presence`) further narrows that to waiters whose
  phone is actually connected right now (design-qa.md Q55's ~30s grace
  window lives at the Presence layer, not here).
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Repo
  alias Tabletap.Staffing.Shift
  alias Tabletap.Tenants.Membership

  @doc "Clocks the current membership in — a fresh open shift. `{:error, :already_clocked_in}` if one exists."
  def clock_in(%Scope{org: org, venue: venue, membership: membership}) do
    case get_open_shift_query(membership.id) |> Repo.one() do
      nil ->
        Shift.clock_in_changeset(org.id, venue.id, membership.id) |> Repo.insert()

      %Shift{} ->
        {:error, :already_clocked_in}
    end
  end

  @doc "Clocks the current membership out. `{:error, :not_clocked_in}` if there's no open shift."
  def clock_out(%Scope{membership: membership}) do
    case get_open_shift_query(membership.id) |> Repo.one() do
      nil -> {:error, :not_clocked_in}
      %Shift{} = shift -> shift |> Shift.clock_out_changeset() |> Repo.update()
    end
  end

  @doc "The current membership's open shift, or `nil`."
  def get_open_shift(%Scope{membership: membership}) do
    get_open_shift_query(membership.id) |> Repo.one()
  end

  defp get_open_shift_query(membership_id) do
    from(s in Shift, where: s.membership_id == ^membership_id and is_nil(s.ended_at))
  end

  @doc """
  Every `:waiter` membership currently on an open shift at `venue_id` —
  the assignment algorithm's raw candidate pool, before the Presence
  liveness filter narrows it further (`Tabletap.Ordering.assign_waiter/1`).
  """
  def list_on_shift_waiter_membership_ids(venue_id) do
    from(s in Shift,
      join: m in Membership,
      on: m.id == s.membership_id,
      where: s.venue_id == ^venue_id and is_nil(s.ended_at) and m.role == :waiter and m.active,
      select: m.id
    )
    |> Repo.all()
  end

  @doc """
  Force-ends `membership`'s open shift (design-qa.md Q44 — membership
  deactivation). Returns `{:ok, shift}` if one was open, `{:ok, nil}` if
  not. Handing open orders to the claim board is the caller's job
  (`Ordering.unassign_and_escalate/2`) — this function only owns the
  shift record.
  """
  def force_end_shift(%Scope{}, %Membership{} = membership) do
    case get_open_shift_query(membership.id) |> Repo.one() do
      nil -> {:ok, nil}
      %Shift{} = shift -> shift |> Shift.clock_out_changeset() |> Repo.update()
    end
  end

  @doc "Whether `membership_id` currently has an open shift — used to gate the assignment solo-waiter shortcut and general candidacy."
  def on_shift?(membership_id) do
    get_open_shift_query(membership_id) |> Repo.exists?()
  end
end
