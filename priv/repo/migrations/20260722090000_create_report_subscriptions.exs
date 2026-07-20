defmodule Tabletap.Repo.Migrations.CreateReportSubscriptions do
  use Ecto.Migration

  def change do
    # build-plan.md Feature 18 / owner-dashboard.md's Report Center —
    # scheduled email delivery. One row per (membership, venue, report
    # type): a manager can subscribe the same report at daily/weekly/
    # monthly cadence, but not twice at the same cadence. The worker
    # re-checks the membership's `active` flag + role fresh at send
    # time (design-qa.md Q52) rather than eagerly purging on
    # deactivation — nothing in this codebase deactivates a membership
    # yet (`Staffing.force_end_shift/2` is unused), so there is no
    # eager-purge hook to wire up until that feature exists.
    create table(:report_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :membership_id,
          references(:memberships,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :report_type, :string, null: false
      add :frequency, :string, null: false
      add :last_sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:report_subscriptions, [:org_id])
    create index(:report_subscriptions, [:venue_id])

    create unique_index(
             :report_subscriptions,
             [:membership_id, :venue_id, :report_type, :frequency],
             name: :report_subscriptions_membership_venue_report_frequency_index
           )
  end
end
