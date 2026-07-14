defmodule Tabletap.Repo.Migrations.AddPickupTimeoutToVenues do
  use Ecto.Migration

  def change do
    # design-qa.md Q32 — minutes a `ready` pickup-mode order sits
    # uncollected before the sweep flags it `not_picked_up`. Only
    # meaningful for `fulfillment_mode: :pickup` venues, but lives here
    # rather than gated some other way — same shape as every other
    # per-venue tunable (business_day_cutoff, eta_inflation_factor).
    alter table(:venues) do
      add :pickup_timeout_minutes, :integer, null: false, default: 15
    end
  end
end
