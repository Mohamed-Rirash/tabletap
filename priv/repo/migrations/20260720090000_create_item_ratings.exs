defmodule Tabletap.Repo.Migrations.CreateItemRatings do
  use Ecto.Migration

  def change do
    # architecture.md's own data-model row: "org_id, venue_id,
    # order_item_id (unique), menu_item_id, customer_user_id, stars
    # (1-5), comment — one rating per served order item."
    # `customer_user_id` is nullable — the tracker never requires an
    # account to rate (same zero-login philosophy as ordering itself);
    # `on_delete: :nilify_all` matches design-qa.md Q15 "ratings kept
    # aggregate-only" on customer deletion — the row survives, only the
    # identity link is severed. Immutable once given (no updated_at) —
    # build-plan.md never describes editing a rating.
    create table(:item_ratings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :order_item_id,
          references(:order_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      # :restrict, not :nilify_all — menu items are archive-not-delete
      # once referenced by any order (Q41), so this FK never actually
      # fires on a real dish; keep it strict rather than silently
      # letting a rating point at nothing.
      add :menu_item_id,
          references(:menu_items,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :customer_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :stars, :integer, null: false
      add :comment, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:item_ratings, [:org_id])
    create unique_index(:item_ratings, [:order_item_id])
    # The public menu's per-item average and the manager feedback
    # screen's per-item filter both query "every rating for this item,
    # newest first" — the natural index shape for both.
    create index(:item_ratings, [:menu_item_id, :inserted_at])
    create index(:item_ratings, [:venue_id, :inserted_at])

    create constraint(:item_ratings, :stars_between_1_and_5, check: "stars >= 1 AND stars <= 5")
  end
end
