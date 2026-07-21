defmodule Tabletap.Notifications.Workers.SendPush do
  @moduledoc """
  Fire-and-forget Web Push delivery (build-plan.md Feature 20) — the
  only real caller of `Notifications.notify_user/2`. Runs in the
  `:notifications` queue (reserved since Feature 18, unused until
  now). `max_attempts: 1`, same reasoning `Workers.ChargeOrder`
  already documents for a push-style external call: a push failure
  never blocks or retries the request that triggered it —
  `Notifications.send_push/2`'s own dead-subscription cleanup handles
  the routine failure case, and a genuinely down push service just
  means this one notification is missed, not that the underlying
  order/alert itself failed.

  `"stuck_order"` (build-plan.md Feature 21) is enqueued by
  `Ordering.Workers.StuckOrderWatchdog` with its own Oban `unique`
  constraint keyed on the order's id — this worker stays agnostic to
  that; it just delivers whatever job reaches it.

  Runs without a request scope, same as every other Oban job in this
  codebase (`Workers.ChargeOrder`'s own moduledoc: "Oban jobs run
  without a request scope") — `Repo.put_org_id/1` is set here from the
  job's own `org_id` arg before resolving *who* to push to.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 1

  alias Tabletap.Notifications
  alias Tabletap.Repo
  alias Tabletap.Tenants

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"type" => "waiter", "org_id" => org_id, "membership_id" => membership_id} = args
      }) do
    Repo.put_org_id(org_id)

    case Tenants.get_membership_user_id(membership_id) do
      nil -> :ok
      user_id -> Notifications.notify_user(user_id, payload(args))
    end

    :ok
  end

  # Same manager/owner audience for both — a stuck-order alert
  # (build-plan.md Feature 21) is delivered exactly like a low-stock one.
  def perform(%Oban.Job{
        args: %{"type" => type, "org_id" => org_id, "venue_id" => venue_id} = args
      })
      when type in ["low_stock", "stuck_order"] do
    Repo.put_org_id(org_id)

    venue_id
    |> Tenants.list_manager_and_owner_user_ids()
    |> Enum.each(&Notifications.notify_user(&1, payload(args)))

    :ok
  end

  defp payload(%{"title" => title, "body" => body, "url" => url}) do
    %{title: title, body: body, url: url}
  end
end
