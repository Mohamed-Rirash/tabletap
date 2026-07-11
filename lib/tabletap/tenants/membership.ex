defmodule Tabletap.Tenants.Membership do
  @moduledoc """
  Per-venue staff role (architecture.md "Data Model"). Owner rows have
  `venue_id: nil` — an owner's authority is org-wide, not tied to one
  venue. Every other role is pinned to exactly one venue.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "memberships" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :user, Tabletap.Accounts.User

    field :role, Ecto.Enum, values: [:owner, :manager, :cashier, :waiter, :kitchen]
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:org_id, :venue_id, :user_id, :role, :active])
    |> validate_required([:org_id, :user_id, :role])
    |> validate_owner_has_no_venue()
    |> validate_staff_has_venue()
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:org_id, :venue_id, :user_id],
      name: :memberships_org_venue_user_index,
      message: "already has a membership for this venue"
    )
    # Owner rows have venue_id: nil, so they never hit the index above
    # (Postgres treats every NULL as distinct in a unique index) — this
    # partial index is what actually stops a duplicate owner membership.
    |> unique_constraint([:org_id, :user_id],
      name: :memberships_org_user_owner_index,
      message: "is already an owner of this organization"
    )
  end

  defp validate_owner_has_no_venue(changeset) do
    if get_field(changeset, :role) == :owner and get_field(changeset, :venue_id) do
      add_error(changeset, :venue_id, "must be blank for an owner (org-wide role)")
    else
      changeset
    end
  end

  defp validate_staff_has_venue(changeset) do
    role = get_field(changeset, :role)

    if role in [:manager, :cashier, :waiter, :kitchen] and is_nil(get_field(changeset, :venue_id)) do
      add_error(changeset, :venue_id, "is required for the #{role} role")
    else
      changeset
    end
  end
end
