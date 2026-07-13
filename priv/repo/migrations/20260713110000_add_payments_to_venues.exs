defmodule Tabletap.Repo.Migrations.AddPaymentsToVenues do
  use Ecto.Migration

  def change do
    alter table(:venues) do
      # build-plan.md Feature 09 (design-qa.md Q57/Q58) — nil until the
      # venue has done the offline WaafiPay paperwork and pasted
      # credentials into Manager.PaymentSettingsLive. `charges_enabled`
      # only flips true after a successful verification lookup, mirroring
      # how `Tenants.Venue.opening_hours: nil` means "gate never blocks" —
      # here the equivalent safe default is "checkout blocks until real
      # credentials are verified," never a silent false-positive.
      add :payment_provider, :string
      add :charges_enabled, :boolean, null: false, default: false

      # WaafiPay merchant credentials, encrypted at rest (Tabletap.Vault,
      # library-docs.md "Venue credentials decrypt just-in-time per call").
      # store_id/hpp_key are only needed for the Hosted Payment Page path,
      # not the direct API_PURCHASE flow this feature builds — nullable.
      add :waafipay_merchant_uid, :binary
      add :waafipay_api_user_id, :binary
      add :waafipay_api_key, :binary
      add :waafipay_store_id, :binary
      add :waafipay_hpp_key, :binary
    end
  end
end
