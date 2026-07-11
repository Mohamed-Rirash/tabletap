defmodule Tabletap.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    # Roll all the way back regardless of which version we migrated up to.
    Oban.Migration.down(version: 1)
  end
end
