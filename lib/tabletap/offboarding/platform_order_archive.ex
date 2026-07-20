defmodule Tabletap.Offboarding.PlatformOrderArchive do
  @moduledoc """
  An anonymized, platform-level stub of one order (build-plan.md
  Feature 19; design-qa.md Q31: "before tenant hard-delete, orders
  belonging to account-holding customers are copied to a platform-
  level archive... venue identity dies with the tenant; the customer's
  own record of what they ate and spent does not"). Deliberately flat
  — no FK to the org/venue being deleted, only to the customer whose
  history this preserves.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "platform_order_archives" do
    belongs_to :customer_user, Tabletap.Accounts.User, foreign_key: :customer_user_id

    field :venue_name_snapshot, :string
    field :order_date, :date
    field :items, :map
    field :total, Money.Ecto.Composite.Type

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
