defmodule Tabletap.Repo.Migrations.CreateDevicePushTokens do
  use Ecto.Migration

  def change do
    # build-plan.md Feature 23 — Expo push tokens for the mobile apps,
    # fanned out alongside `push_subscriptions` (Feature 20) from the
    # same `Notifications.notify_user/2` entry point. Not tenant-owned,
    # same reasoning as `push_subscriptions`/`users`/`user_tokens`: a
    # device belongs to a person, not a tenant. A separate table rather
    # than a column on `push_subscriptions` — Expo's model (one opaque
    # `ExponentPushToken[...]` string) shares nothing structurally with
    # Web Push's `endpoint`/`p256dh`/`auth` triple.
    create table(:device_push_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :token, :text, null: false
      # Diagnostic only — never parsed/trusted for anything functional,
      # same as push_subscriptions.user_agent.
      add :platform, :string

      timestamps(type: :utc_datetime)
    end

    create index(:device_push_tokens, [:user_id])
    # A physical device's token is unique across the whole table, not
    # just per-user — re-registering the same device (app reinstall,
    # token refresh) upserts onto the existing row and, if it moved to
    # a different account since, reassigns it rather than creating a
    # stale duplicate.
    create unique_index(:device_push_tokens, [:token])
  end
end
