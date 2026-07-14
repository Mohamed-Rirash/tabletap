defmodule Tabletap.Ordering.Workers.AssignWaiter do
  @moduledoc """
  Runs the waiter-assignment algorithm for a freshly-`placed` order
  (build-plan.md Feature 10) — enqueued by
  `OrderStateMachine.transition/3` after the `placed` transaction
  commits, never inline (architecture.md "Side-effects are Oban jobs...
  a crash mid-assignment survives restart and re-runs; idempotency means
  a retry can never double-assign").

  Args carry `org_id` explicitly, same as `Payments.Workers.ChargeOrder`
  (library-docs.md "Oban jobs run without a request scope: they build
  their own scope from the args' org").
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Accounts.Scope
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Order
  alias Tabletap.Repo
  alias Tabletap.Tenants.{Org, Venue}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id, "org_id" => org_id}}) do
    Repo.put_org_id(org_id)

    case Repo.one(from(o in Order, where: o.id == ^order_id)) do
      # Deleted/cancelled between enqueue and run — nothing to assign.
      nil ->
        :ok

      %Order{} = order ->
        venue = Repo.one(from(v in Venue, where: v.id == ^order.venue_id))
        org = Repo.one(from(o in Org, where: o.id == ^org_id), skip_org_id: true)
        scope = %Scope{org: org, venue: venue, role: nil}

        case Ordering.assign_waiter(scope, order) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
