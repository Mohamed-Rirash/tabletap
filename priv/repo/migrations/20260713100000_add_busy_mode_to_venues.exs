defmodule Tabletap.Repo.Migrations.AddBusyModeToVenues do
  use Ecto.Migration

  def change do
    alter table(:venues) do
      # design-qa.md Q2 "Busy Mode" — Pause (nil = not paused; a future
      # timestamp = paused until then; "until reopened" uses a far-future
      # sentinel — Venue.indefinite_pause_sentinel/0 — rather than a second
      # boolean column) and Slow (ETA inflation multiplier, default 1.0 =
      # no inflation).
      add :ordering_paused_until, :utc_datetime
      add :eta_inflation_factor, :decimal, null: false, default: 1.0

      # nil = always open (safe default — no manager-facing editor ships
      # in this feature, so a venue can never accidentally lock itself
      # out of ordering by this gate existing). Shape: %{"monday" => [%{
      # "open" => "08:00", "close" => "22:00"}], ...} plus an optional
      # "overrides" key for date-specific holidays/special hours
      # (architecture.md).
      add :opening_hours, :map
    end
  end
end
