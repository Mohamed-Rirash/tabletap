defmodule Tabletap.Analytics.Workers.DailyRollup do
  @moduledoc """
  Nightly rollup job (build-plan.md Feature 18) — cross-tenant, same
  shape as `Staffing.Workers.AutoCloseShifts`: loops `Tenants.list_org_ids/0`
  + `Repo.put_org_id/1` per org, then a normal tenant-scoped read/write.

  Recomputes the **last 7 business days** for every venue, not just the
  day that just closed. This is a deliberate, documented interpretation
  of design-qa.md Q38 ("late-arriving orders/payments on a past business
  day...appear as flagged post-close adjustments"): rather than
  threading an explicit "enqueue a recompute for date X" call through
  every `Ordering`/`Payments` write path that could conceivably land a
  late event (a webhook retry, a delayed refund, a manual adjustment),
  a rolling 7-day re-scan is self-healing within a week without
  touching any code outside `Analytics`. `Analytics.upsert_rollup/2`'s
  `recompute_count` is the signal a reader uses to notice a day's
  numbers moved since they first appeared — see `Analytics`'s own
  moduledoc for the full reasoning.
  """
  use Oban.Worker, queue: :rollups, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Accounts.Scope
  alias Tabletap.Analytics
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.{Org, Venue}

  @lookback_days 7

  @impl Oban.Worker
  def perform(_job) do
    total =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)
        acc + rollup_org(org_id)
      end)

    :telemetry.execute([:tabletap, :analytics, :rollups_computed], %{count: total}, %{})
    :ok
  end

  defp rollup_org(org_id) do
    venues = Repo.all(from(v in Venue, where: is_nil(v.archived_at)))

    if venues == [] do
      0
    else
      org = Repo.one(from(o in Org, where: o.id == ^org_id), skip_org_id: true)

      Enum.reduce(venues, 0, fn venue, acc ->
        acc + rollup_venue(org, venue)
      end)
    end
  end

  defp rollup_venue(org, venue) do
    scope = %Scope{org: org, venue: venue}

    venue
    |> Analytics.recent_business_dates(@lookback_days)
    |> Enum.each(fn date ->
      scope
      |> Analytics.compute_rollup(date)
      |> Analytics.upsert_rollup()
    end)

    @lookback_days
  end
end
