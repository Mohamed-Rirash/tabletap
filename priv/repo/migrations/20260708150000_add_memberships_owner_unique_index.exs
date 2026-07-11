defmodule Tabletap.Repo.Migrations.AddMembershipsOwnerUniqueIndex do
  use Ecto.Migration

  # The existing memberships_org_venue_user_index on (org_id, venue_id,
  # user_id) does not stop duplicate OWNER memberships — owner rows always
  # have venue_id: NULL, and Postgres treats every NULL as distinct from
  # every other NULL in a unique index, so two owner rows for the same
  # org+user pass it silently (verified empirically: two such rows insert
  # without error under the old schema). This partial unique index, scoped
  # to WHERE venue_id IS NULL, closes that specifically for the owner
  # case; the existing index keeps doing its job for every venue-scoped
  # role.
  def change do
    create unique_index(:memberships, [:org_id, :user_id],
             where: "venue_id IS NULL",
             name: :memberships_org_user_owner_index
           )
  end
end
