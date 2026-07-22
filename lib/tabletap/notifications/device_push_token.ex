defmodule Tabletap.Notifications.DevicePushToken do
  @moduledoc """
  One physical device's Expo push token (build-plan.md Feature 23). Not
  tenant-owned — belongs to a `User`, not an org, same reasoning as
  `PushSubscription`'s own moduledoc.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "device_push_tokens" do
    belongs_to :user, Tabletap.Accounts.User

    field :token, :string
    field :platform, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(device_push_token, attrs) do
    device_push_token
    |> cast(attrs, [:user_id, :token, :platform])
    |> validate_required([:user_id, :token])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token)
  end
end
