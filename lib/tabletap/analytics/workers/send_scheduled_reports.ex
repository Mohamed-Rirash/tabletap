defmodule Tabletap.Analytics.Workers.SendScheduledReports do
  @moduledoc """
  Nightly scheduled-report delivery (build-plan.md Feature 18) —
  cross-tenant, same loop shape as `Analytics.Workers.DailyRollup`:
  `Tenants.list_org_ids/0` + `Repo.put_org_id/1` per org, then
  `Reports.due_subscriptions/1` (scoped by that ambient org_id, same
  as any other tenant-owned read) to find what's due.

  "Due" mirrors `Workers.DailyRollup`'s own fixed-schedule
  simplification — daily fires every day, weekly on Mondays, monthly
  on the 1st, checked against `Date.utc_today/0` rather than each
  subscription's own signup anchor date.

  Every subscription is re-checked against its **current** membership
  (`active` + `role in [:owner, :manager]`) immediately before sending
  — design-qa.md Q52: "opt in to the daily revenue email, get fired,
  keep receiving the venue's numbers every morning is a real data
  leak." Nothing eagerly purges a subscription on deactivation (no
  code path deactivates a membership yet — `Staffing.force_end_shift/2`
  is unused in `lib/`), so this send-time check is the only gate; once
  a real deactivation flow exists, purging subscriptions there too is
  a cheap addition on top of this same guard.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Accounts.{Scope, User}
  alias Tabletap.Analytics.{ReportNotifier, Reports}
  alias Tabletap.Analytics.Reports.Csv
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.Org

  @impl Oban.Worker
  def perform(_job) do
    today = Date.utc_today()

    sent =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)
        acc + send_due(org_id, today)
      end)

    :telemetry.execute([:tabletap, :analytics, :scheduled_reports_sent], %{count: sent}, %{})
    :ok
  end

  defp send_due(org_id, today) do
    # Same `skip_org_id: true` exception `Workers.DailyRollup` already
    # takes for this exact lookup: `orgs` has no `org_id` column (an
    # org *is* the tenant), so this can't ride the ambient scope
    # `due_subscriptions/1`'s own query relies on.
    org = Repo.one(from(o in Org, where: o.id == ^org_id), skip_org_id: true)
    subscriptions = Reports.due_subscriptions(today)
    users_by_id = users_by_membership_user_id(subscriptions)

    Enum.count(subscriptions, &send_one(&1, org, users_by_id))
  end

  # `users` has no `org_id` column either — same two-query shape as
  # `Tenants.list_memberships/2`'s own comment explains.
  defp users_by_membership_user_id(subscriptions) do
    user_ids = subscriptions |> Enum.map(& &1.membership.user_id) |> Enum.uniq()

    Repo.all(from(u in User, where: u.id in ^user_ids), skip_org_id: true)
    |> Map.new(&{&1.id, &1})
  end

  defp send_one(
         %{membership: %{active: true, role: role} = membership} = subscription,
         org,
         users_by_id
       )
       when role in [:owner, :manager] do
    user = Map.fetch!(users_by_id, membership.user_id)

    scope = %Scope{
      org: org,
      venue: subscription.venue,
      membership: membership,
      role: role,
      user: user
    }

    {from_date, to_date} = Reports.subscription_range(subscription.venue, subscription.frequency)
    data = Reports.generate(subscription.report_type, scope, from_date, to_date)
    csv = Csv.render(subscription.report_type, data)

    case ReportNotifier.deliver_scheduled_report(
           user,
           subscription.report_type,
           subscription.frequency,
           from_date,
           to_date,
           csv
         ) do
      {:ok, _email} ->
        Reports.mark_sent(subscription)
        true

      {:error, _reason} ->
        false
    end
  end

  defp send_one(_subscription, _org, _users_by_id), do: false
end
