defmodule Tabletap.Tenants.Org do
  @moduledoc """
  The tenant. Not itself org-scoped (it IS the scope) — every query against
  this schema needs `skip_org_id: true`, allowed only from `Tabletap.Tenants`
  (code-standards.md).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tabletap.Tenants.Slug

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "orgs" do
    field :name, :string
    field :slug, :string

    # pricing.md (design-qa.md Q63) — feature-tiered plans, not just venue
    # count. Every org starts on trial, defaulting to Essentials once it
    # converts (the trial itself unlocks every tier's features).
    field :plan, Ecto.Enum, values: [:essentials, :growth, :pro], default: :essentials

    field :subscription_status, Ecto.Enum,
      values: [:trialing, :active, :past_due, :canceled],
      default: :trialing

    field :trial_ends_at, :utc_datetime

    # The owner's own wallet number (build-plan.md Feature 19) — who
    # Tabletap's platform merchant account pushes the monthly
    # subscription PIN prompt *to* (design-qa.md Q59). Nullable: unset
    # until the owner visits the billing screen at least once, distinct
    # from any venue's own WaafiPay merchant credentials (those receive
    # customer payments).
    field :billing_wallet_msisdn, :string

    # build-plan.md Feature 19 / design-qa.md Q15 — owner-initiated
    # offboarding start; nil for every org that hasn't asked to leave.
    # `Tabletap.Offboarding.Workers.PurgeOffboardedTenants` hard-deletes
    # this org (Q31/Q54's archival happens first) once 90 days have
    # passed since this timestamp.
    field :offboarding_requested_at, :utc_datetime

    # build-plan.md Feature 21 — the one org backing the synthetic
    # order-flow health-check endpoint (`/healthz/order-flow`), so an
    # external uptime monitor can exercise the real QR→menu code path
    # without a real venue's data ever being involved. Excluded from
    # `Tabletap.Admin.list_tenants/0` — an ops fixture, not a customer.
    field :synthetic, :boolean, default: false

    has_many :venues, Tabletap.Tenants.Venue
    has_many :memberships, Tabletap.Tenants.Membership

    timestamps(type: :utc_datetime)
  end

  @trial_days 14

  @doc """
  Changeset for a brand-new org at signup — always starts trialing with a
  #{@trial_days}-day trial, no card required (design-qa.md Q29).
  """
  def registration_changeset(org, attrs) do
    org
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 120)
    |> put_slug()
    |> put_change(:plan, :essentials)
    |> put_change(:subscription_status, :trialing)
    |> put_change(:trial_ends_at, DateTime.add(DateTime.utc_now(:second), @trial_days, :day))
  end

  @doc "Sets the owner's own wallet number — who `Tabletap.Billing`'s platform merchant account pushes the monthly subscription PIN prompt to (design-qa.md Q59). No format regex: same as checkout's own wallet_msisdn, the provider round-trip is the real validation, not client-side guessing at a phone format."
  def billing_wallet_changeset(org, attrs) do
    org
    |> cast(attrs, [:billing_wallet_msisdn])
    |> validate_required([:billing_wallet_msisdn])
  end

  defp put_slug(changeset) do
    case get_field(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, Slug.generate(name))
    end
  end
end
