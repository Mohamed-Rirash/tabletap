defmodule Tabletap.Repo.Migrations.AddPlatformAdminToUsers do
  use Ecto.Migration

  def change do
    # build-plan.md Feature 19 — "Platform Admin (us) — Admin panel,
    # us only" (role-features.md). No self-serve way to become one:
    # this flag is set directly (console/seed), never through any UI
    # this app exposes. A platform admin is not a member of any
    # tenant — this lives on `users`, not `memberships`.
    alter table(:users) do
      add :platform_admin, :boolean, null: false, default: false
    end
  end
end
