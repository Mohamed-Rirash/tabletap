defmodule Tabletap.Ordering.Workers.EscalateUnacceptedOrder do
  @moduledoc """
  The 90s accept window (build-plan.md Feature 10; library-docs.md's own
  Oban example, followed shape for shape): scheduled at assignment time,
  and re-checks current state before acting — the waiter may have
  accepted, the manager may have reassigned, or the order may have been
  cancelled while this job waited. Only a still-`:placed` order still
  assigned to the *same* membership escalates to the claim board
  (jobs are delayed truth, never assumed truth).
  """
  use Oban.Worker, queue: :escalations, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Accounts.Scope
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Order
  alias Tabletap.Repo
  alias Tabletap.Tenants.{Org, Venue}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "order_id" => order_id,
          "org_id" => org_id,
          "assigned_membership_id" => membership_id
        }
      }) do
    Repo.put_org_id(org_id)

    case Repo.one(from(o in Order, where: o.id == ^order_id)) do
      %Order{status: :placed, waiter_membership_id: ^membership_id} = order ->
        venue = Repo.one(from(v in Venue, where: v.id == ^order.venue_id))
        org = Repo.one(from(o in Org, where: o.id == ^org_id), skip_org_id: true)
        {:ok, _} = Ordering.escalate_to_claim_board(%Scope{org: org, venue: venue}, order)
        :ok

      # Accepted / reassigned / cancelled / gone — nothing to do.
      _ ->
        :ok
    end
  end
end
