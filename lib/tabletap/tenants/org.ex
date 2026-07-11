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

  defp put_slug(changeset) do
    case get_field(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, Slug.generate(name))
    end
  end
end
