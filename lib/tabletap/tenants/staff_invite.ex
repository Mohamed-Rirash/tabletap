defmodule Tabletap.Tenants.StaffInvite do
  @moduledoc """
  Invite-link onboarding for staff (architecture.md "Data Model"). Schema
  only in Feature 03 — invite-creation and acceptance LiveViews are a
  follow-up (build-plan.md Feature 03 scopes schemas + migrations; the
  fuller "Staff management" UI lands with the back office).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "staff_invites" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue

    field :email, :string
    field :role, Ecto.Enum, values: [:manager, :cashier, :waiter, :kitchen]
    field :token, :string
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @invite_ttl_days 7

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:org_id, :venue_id, :email, :role])
    |> validate_required([:org_id, :venue_id, :email, :role])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:venue_id)
    |> put_change(:token, generate_token())
    |> put_change(:expires_at, DateTime.add(DateTime.utc_now(:second), @invite_ttl_days, :day))
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
