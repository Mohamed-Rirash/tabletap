defmodule Tabletap.Repo.Migrations.CreateOrderNumberCounters do
  use Ecto.Migration

  def change do
    create table(:order_number_counters, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :business_date, :date, null: false
      add :next_number, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:order_number_counters, [:org_id])

    # The atomic upsert-increment target (Ordering.reserve_order_number/3
    # via Repo.insert_all on_conflict: [inc: ...], conflict_target: this).
    create unique_index(:order_number_counters, [:venue_id, :business_date])
  end
end
