defmodule Tabletap.Offboarding.Workers.PurgeOffboardedTenants do
  @moduledoc """
  Nightly offboarding sweep (build-plan.md Feature 19; design-qa.md
  Q15/Q31/Q54). Cross-tenant by design — every org is a candidate
  regardless of which tenant it belongs to, so this queries with
  `skip_org_id: true` throughout (`Tabletap.Offboarding` itself does
  too) rather than looping `Repo.put_org_id/1` per org the way
  `Analytics.Workers.DailyRollup` does — there's no normal
  tenant-scoped read happening here to protect.

  Finds every org whose `offboarding_requested_at` is 90+ days old and
  hard-deletes it via `Offboarding.archive_and_hard_delete/1`
  (archiving customer order history and payment/dispute evidence
  first), then purges any dispute-evidence snapshot whose own 180-day
  retention window has elapsed.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 1

  import Ecto.Query

  alias Tabletap.Offboarding
  alias Tabletap.Repo
  alias Tabletap.Tenants.Org

  @offboarding_days 90

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@offboarding_days, :day)

    Repo.all(
      from(o in Org,
        where: not is_nil(o.offboarding_requested_at) and o.offboarding_requested_at <= ^cutoff
      ),
      skip_org_id: true
    )
    |> Enum.each(&Offboarding.archive_and_hard_delete/1)

    Offboarding.purge_expired_dispute_records()

    :ok
  end
end
