defmodule Tabletap.Ordering.Workers.SweepAbandonedCartsTest do
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Ecto.Query
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo}
  alias Tabletap.Ordering.Cart
  alias Tabletap.Ordering.Workers.SweepAbandonedCarts

  defp item_fixture(scope) do
    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    item
  end

  defp add_cart(scope, age_hours) do
    item = item_fixture(scope)
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)

    stale_at =
      DateTime.add(DateTime.utc_now(), -age_hours * 60 * 60, :second)
      |> DateTime.truncate(:second)

    Repo.update_all(from(c in Cart, where: c.id == ^cart.id), set: [updated_at: stale_at])

    cart.id
  end

  test "abandons stale active carts across every org, leaves fresh ones alone" do
    %{org: org_a, venue: venue_a} = org_fixture()
    %{org: org_b, venue: venue_b} = org_fixture()

    Repo.put_org_id(org_a.id)
    scope_a = %Scope{org: org_a, venue: venue_a}
    stale_a = add_cart(scope_a, 25)
    fresh_a = add_cart(scope_a, 1)

    Repo.put_org_id(org_b.id)
    scope_b = %Scope{org: org_b, venue: venue_b}
    stale_b = add_cart(scope_b, 48)

    assert :ok = perform_job(SweepAbandonedCarts, %{})

    Repo.put_org_id(org_a.id)
    assert Repo.get(Cart, stale_a).status == :abandoned
    assert Repo.get(Cart, fresh_a).status == :active

    Repo.put_org_id(org_b.id)
    assert Repo.get(Cart, stale_b).status == :abandoned
  end

  test "a venue with no carts at all is a no-op, not a crash" do
    %{} = org_fixture()
    assert :ok = perform_job(SweepAbandonedCarts, %{})
  end
end
