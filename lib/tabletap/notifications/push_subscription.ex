defmodule Tabletap.Notifications.PushSubscription do
  @moduledoc """
  One browser's Web Push subscription (build-plan.md Feature 20). Not
  tenant-owned — belongs to a `User`, not an org (see the migration's
  own comment for why). `endpoint`/`p256dh`/`auth` are exactly the
  three fields a browser's `PushSubscription.toJSON()` returns, fed
  straight to `WebPushEx.Subscription.from_json/1` at send time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "push_subscriptions" do
    belongs_to :user, Tabletap.Accounts.User

    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :user_agent, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :endpoint, :p256dh, :auth, :user_agent])
    |> validate_required([:user_id, :endpoint, :p256dh, :auth])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :endpoint])
  end
end
