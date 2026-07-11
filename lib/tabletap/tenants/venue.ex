defmodule Tabletap.Tenants.Venue do
  @moduledoc """
  One restaurant/café location (architecture.md "Data Model"). Only the
  identity/regional fields land in Feature 03 — payment credentials
  (Feature 09), Busy Mode fields (Feature 08), and pickup timeout
  (Feature 10/11) get added by the features that need them, each in its
  own migration, rather than speculatively created here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tabletap.Tenants.Slug

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "venues" do
    belongs_to :org, Tabletap.Tenants.Org

    field :name, :string
    field :slug, :string
    field :currency, :string
    field :timezone, :string
    field :locale, :string, default: "so"
    field :business_day_cutoff, :time, default: ~T[04:00:00]
    field :fulfillment_mode, Ecto.Enum, values: [:waiter, :pickup], default: :waiter
    field :archived_at, :utc_datetime

    has_many :memberships, Tabletap.Tenants.Membership

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a venue created alongside its org at signup. `attrs` is
  expected to already carry a resolved `currency`/`timezone` (the signup
  form offers a city picker, not raw IANA zone entry — `Tenants.city_options/0`).
  """
  def registration_changeset(venue, attrs) do
    venue
    |> cast(attrs, [:name, :currency, :timezone, :locale])
    |> validate_required([:name, :currency, :timezone])
    |> validate_length(:name, min: 2, max: 120)
    |> put_slug()
  end

  defp put_slug(changeset) do
    case get_field(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, Slug.generate(name))
    end
  end
end
