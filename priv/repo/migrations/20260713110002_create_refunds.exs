defmodule Tabletap.Repo.Migrations.CreateRefunds do
  use Ecto.Migration

  def change do
    create table(:refunds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :payment_id,
          references(:payments, type: :binary_id, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :amount, :money_with_currency, null: false
      add :reason, :text, null: false
      # nullable — null means a cash refund (design-qa.md Q22), not a
      # missing value; a wallet refund always carries the provider's id.
      add :provider_refund_id, :string
      add :status, :string, null: false, default: "pending"
      # `users`, not `memberships` — refunds are attributed to the staff
      # member who acted, and `users` is the shared, non-tenant-owned
      # identity table every membership already points at.
      add :staff_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:refunds, [:org_id])
    create index(:refunds, [:payment_id])
    create index(:refunds, [:staff_user_id])
  end
end
