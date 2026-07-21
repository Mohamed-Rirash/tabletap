defmodule Tabletap.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  def change do
    # build-plan.md Feature 20; architecture.md's own "notifications/ →
    # Web push subscriptions, notification fan-out". Not tenant-owned —
    # same reasoning as `users`/`user_tokens` (Tabletap.Accounts' own
    # moduledoc): a browser subscription belongs to a *person*, not a
    # tenant, since a waiter/manager can hold memberships (and receive
    # pushes) across more than one org. `Tabletap.Notifications`
    # resolves "who to push" from a domain event down to a `user_id`
    # and reads this table with `skip_org_id: true`, same as `Accounts`.
    create table(:push_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false
      # Diagnostic only — never parsed/trusted for anything functional.
      add :user_agent, :string

      timestamps(type: :utc_datetime)
    end

    create index(:push_subscriptions, [:user_id])
    # Re-subscribing the same browser (a token refresh, a re-granted
    # permission) is idempotent — an upsert on this index, never a
    # second row for the same device.
    create unique_index(:push_subscriptions, [:user_id, :endpoint])
  end
end
