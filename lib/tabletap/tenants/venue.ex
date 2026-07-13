defmodule Tabletap.Tenants.Venue do
  @moduledoc """
  One restaurant/café location (architecture.md "Data Model"). Only the
  identity/regional fields land in Feature 03 — payment credentials
  (Feature 09) and pickup timeout (Feature 10/11) get added by the
  features that need them, each in its own migration, rather than
  speculatively created here. Busy Mode fields land in Feature 08
  (design-qa.md Q2), since checkout is the first real caller.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tabletap.Tenants.Slug

  # "Pause until reopened" (Q2) uses this far-future sentinel instead of a
  # second boolean column — `ordering_paused_until` alone then answers
  # both "is it paused" and "until when" with one comparison.
  @indefinite_pause_sentinel ~U[9999-12-31 23:59:59Z]

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
    field :ordering_paused_until, :utc_datetime
    field :eta_inflation_factor, :decimal, default: Decimal.new(1)
    field :opening_hours, :map
    field :archived_at, :utc_datetime

    has_many :memberships, Tabletap.Tenants.Membership

    timestamps(type: :utc_datetime)
  end

  def indefinite_pause_sentinel, do: @indefinite_pause_sentinel

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

  @doc "Pauses new checkout for `minutes` from now, or indefinitely (\"until reopened\", Q2) when `minutes` is `:indefinite`."
  def pause_changeset(venue, :indefinite) do
    change(venue, ordering_paused_until: @indefinite_pause_sentinel)
  end

  def pause_changeset(venue, minutes) when is_integer(minutes) and minutes > 0 do
    until = DateTime.add(DateTime.utc_now(:second), minutes * 60, :second)
    change(venue, ordering_paused_until: until)
  end

  def resume_changeset(venue), do: change(venue, ordering_paused_until: nil)

  def eta_inflation_changeset(venue, factor) do
    venue
    |> change(eta_inflation_factor: factor)
    |> validate_number(:eta_inflation_factor, greater_than_or_equal_to: 1)
  end

  @doc "Whether checkout is currently paused (Q2 \"Pause\") — `ordering_paused_until` unset, or already in the past."
  def paused?(%__MODULE__{ordering_paused_until: nil}), do: false

  def paused?(%__MODULE__{ordering_paused_until: until}) do
    DateTime.compare(until, DateTime.utc_now()) == :gt
  end
end
