defmodule Tabletap.Ordering.Workers.SweepExpiredHoldsTest do
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Ecto.Query
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, Order}
  alias Tabletap.Ordering.Workers.SweepExpiredHolds
  alias Tabletap.Repo

  defp item_fixture(scope) do
    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    item
  end

  defp stale_pending_order(scope, item, age_minutes) do
    cart_token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, cart_token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)

    stale_at =
      DateTime.add(DateTime.utc_now(), -age_minutes * 60, :second) |> DateTime.truncate(:second)

    Repo.update_all(
      from(o in Order, where: o.id == ^order.id),
      set: [inserted_at: stale_at]
    )

    order.id
  end

  test "expires pending_payment orders past the 12-min hold TTL, releasing the daily-limit hold, across every org" do
    %{org: org_a, venue: venue_a} = org_fixture()
    %{org: org_b, venue: venue_b} = org_fixture()

    Repo.put_org_id(org_a.id)
    scope_a = %Scope{org: org_a, venue: venue_a}
    item_a = item_fixture(scope_a)
    {:ok, _} = Catalog.set_daily_limit(scope_a, item_a, 5)
    stale_id_a = stale_pending_order(scope_a, item_a, 13)
    fresh_id_a = stale_pending_order(scope_a, item_a, 1)

    Repo.put_org_id(org_b.id)
    scope_b = %Scope{org: org_b, venue: venue_b}
    item_b = item_fixture(scope_b)
    {:ok, _} = Catalog.set_daily_limit(scope_b, item_b, 5)
    stale_id_b = stale_pending_order(scope_b, item_b, 20)

    assert :ok = perform_job(SweepExpiredHolds, %{})

    Repo.put_org_id(org_a.id)
    assert Repo.get(Tabletap.Ordering.Order, stale_id_a).status == :expired
    assert Repo.get(Tabletap.Ordering.Order, fresh_id_a).status == :pending_payment
    limit_a = Catalog.get_daily_limit(scope_a, item_a)
    assert limit_a.reserved_qty == 1
    assert limit_a.sold_qty == 0

    Repo.put_org_id(org_b.id)
    assert Repo.get(Tabletap.Ordering.Order, stale_id_b).status == :expired
  end

  test "no orders at all is a no-op, not a crash" do
    %{} = org_fixture()
    assert :ok = perform_job(SweepExpiredHolds, %{})
  end
end
