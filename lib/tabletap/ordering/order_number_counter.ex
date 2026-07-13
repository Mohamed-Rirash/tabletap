defmodule Tabletap.Ordering.OrderNumberCounter do
  @moduledoc """
  One row per `(venue_id, business_date)` — the atomic sequence source for
  `orders.number` (architecture.md; design-qa.md Q39 "order numbers key on
  business date, same cutoff as limits/reports"). Never read-then-written;
  `Ordering.reserve_order_number/3` is the only writer, via
  `Repo.insert_all/3`'s `on_conflict: [inc: [next_number: 1]]` — an atomic
  upsert-increment, not an app-level compare-and-swap.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "order_number_counters" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue

    field :business_date, :date
    field :next_number, :integer, default: 1

    timestamps(type: :utc_datetime)
  end
end
