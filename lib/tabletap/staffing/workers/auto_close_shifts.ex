defmodule Tabletap.Staffing.Workers.AutoCloseShifts do
  @moduledoc """
  Force-closes any shift still open after its venue's business day has
  rolled over (design-qa.md Q45) — a forgotten clock-out never bleeds
  into the next business day's staffing numbers, and is flagged
  `auto_closed` so the employee work report can tell it apart from a
  real end-of-shift. Runs every 15 minutes — shift auto-close has no
  tight latency requirement, unlike the 12-min payment hold sweep.

  Same cross-tenant pattern as `Ordering.Workers.SweepExpiredHolds`:
  loops `Tenants.list_org_ids/0` + `Repo.put_org_id/1` per org.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Staffing.Shift
  alias Tabletap.Tenants.Venue
  alias Tabletap.{Repo, Tenants}

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now(:second)

    total =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)
        acc + auto_close_stale_shifts(now)
      end)

    :telemetry.execute([:tabletap, :staffing, :shifts_auto_closed], %{count: total}, %{})
    :ok
  end

  defp auto_close_stale_shifts(now) do
    open_shifts =
      from(s in Shift, where: is_nil(s.ended_at), preload: :venue)
      |> Repo.all()

    open_shifts
    |> Enum.filter(&crossed_cutoff?(&1, now))
    |> Enum.count(&close!(&1, now))
  end

  defp crossed_cutoff?(%Shift{venue: %Venue{} = venue, started_at: started_at}, now) do
    Tenants.business_date(venue, started_at) != Tenants.business_date(venue, now)
  end

  defp close!(shift, now) do
    shift
    |> Ecto.Changeset.change(ended_at: now, auto_closed: true)
    |> Repo.update!()

    true
  end
end
