defmodule Tabletap.Repo.Migrations.AddSyntheticToOrgs do
  use Ecto.Migration

  def change do
    alter table(:orgs) do
      add :synthetic, :boolean, default: false, null: false
    end
  end
end
