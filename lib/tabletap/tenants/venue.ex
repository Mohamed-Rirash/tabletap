defmodule Tabletap.Tenants.Venue do
  @moduledoc """
  One restaurant/café location (architecture.md "Data Model"). Only the
  identity/regional fields land in Feature 03 — pickup timeout (Feature
  10/11) gets added by the feature that needs it, in its own migration,
  rather than speculatively created here. Busy Mode fields land in
  Feature 08 (design-qa.md Q2). Payment fields land in Feature 09
  (design-qa.md Q57/Q58): `charges_enabled` only flips true after
  `Payments.verify_credentials/2` succeeds — never trust a pasted-in
  credential until it's actually been checked against WaafiPay.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tabletap.Encrypted
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
    # Pickup-mode only (design-qa.md Q32) — minutes a `ready` order sits
    # uncollected before the sweep flags it `not_picked_up`.
    field :pickup_timeout_minutes, :integer, default: 15
    field :ordering_paused_until, :utc_datetime
    field :eta_inflation_factor, :decimal, default: Decimal.new(1)
    field :opening_hours, :map
    field :archived_at, :utc_datetime

    field :payment_provider, Ecto.Enum, values: [:waafipay, :edahab, :chapa, :stripe]
    field :charges_enabled, :boolean, default: false
    field :waafipay_merchant_uid, Encrypted.Binary
    field :waafipay_api_user_id, Encrypted.Binary
    field :waafipay_api_key, Encrypted.Binary
    field :waafipay_store_id, Encrypted.Binary
    field :waafipay_hpp_key, Encrypted.Binary

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

  @doc """
  The manager pastes WaafiPay merchant credentials in at onboarding
  (build-plan.md Feature 09). Saving new credentials always resets
  `charges_enabled` to `false` — a changed credential is unverified
  until `Payments.verify_credentials/2` proves it works again; never
  keep trusting the old verification against new, unchecked values.
  `store_id`/`hpp_key` are optional (only needed for the HPP path, not
  the direct API_PURCHASE flow this feature builds).
  """
  def waafipay_credentials_changeset(venue, attrs) do
    venue
    |> cast(attrs, [
      :waafipay_merchant_uid,
      :waafipay_api_user_id,
      :waafipay_api_key,
      :waafipay_store_id,
      :waafipay_hpp_key
    ])
    |> validate_required([:waafipay_merchant_uid, :waafipay_api_user_id, :waafipay_api_key])
    |> put_change(:payment_provider, :waafipay)
    |> put_change(:charges_enabled, false)
  end

  def verified_changeset(venue) do
    change(venue, charges_enabled: true)
  end

  @doc "Whether `venue` has WaafiPay credentials on file at all (verified or not)."
  def waafipay_credentials?(%__MODULE__{waafipay_merchant_uid: nil}), do: false
  def waafipay_credentials?(%__MODULE__{}), do: true
end
