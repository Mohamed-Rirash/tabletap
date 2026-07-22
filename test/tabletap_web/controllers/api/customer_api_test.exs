defmodule TabletapWeb.Api.CustomerApiTest do
  @moduledoc """
  build-plan.md Feature 23 Commit 2 — menu/cart/checkout/tracker,
  end to end against the real router. `Payments.charge_order/3` only
  enqueues `Workers.ChargeOrder` (never charges inline), so the wallet
  checkout test asserts the job was enqueued rather than mocking
  `Payments.ProviderMock` — the mocked-payment-to-completion path is
  Commit 6's own scripted end-to-end verify, not duplicated here.
  """
  use TabletapWeb.ConnCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo, Tenants}
  alias Tabletap.Payments.Workers.ChargeOrder

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :guest}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{org: org, venue: venue, item: item}
  end

  describe "GET /api/v1/venues/:slug/menu" do
    test "returns categories with items and modifier groups", %{venue: venue, item: item} do
      conn = get(build_conn(), ~p"/api/v1/venues/#{venue.slug}/menu")

      assert %{"categories" => [%{"name" => "Drinks", "items" => [rendered]}]} =
               json_response(conn, 200)

      assert rendered["id"] == item.id
      assert rendered["name"] == "Latte"
      assert rendered["modifier_groups"] == []
    end

    test "404s for an unknown venue slug" do
      conn = get(build_conn(), ~p"/api/v1/venues/does-not-exist/menu")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/venues/:slug/cart/items" do
    test "mints a guest_token and adds the item when none is given", %{venue: venue, item: item} do
      conn =
        post(build_conn(), ~p"/api/v1/venues/#{venue.slug}/cart/items", %{
          "item_id" => item.id,
          "qty" => 2
        })

      assert %{"guest_token" => guest_token, "cart" => %{"items" => [line]}} =
               json_response(conn, 200)

      assert is_binary(guest_token) and byte_size(guest_token) > 0
      assert line["qty"] == 2
      assert line["name"] == "Latte"
    end

    test "reuses a client-supplied guest_token across two adds", %{venue: venue, item: item} do
      guest_token = Ordering.Cart.generate_guest_token()
      attrs = %{"item_id" => item.id, "guest_token" => guest_token, "qty" => 1}

      post(build_conn(), ~p"/api/v1/venues/#{venue.slug}/cart/items", attrs)
      conn = post(build_conn(), ~p"/api/v1/venues/#{venue.slug}/cart/items", attrs)

      assert %{"cart" => %{"items" => [_one, _two]}} = json_response(conn, 200)
    end

    test "404s for an unknown item id", %{venue: venue} do
      conn =
        post(build_conn(), ~p"/api/v1/venues/#{venue.slug}/cart/items", %{
          "item_id" => Ecto.UUID.generate()
        })

      assert json_response(conn, 404)
    end

    test "a malformed item id is a clean 404, not a crash", %{venue: venue} do
      conn =
        post(build_conn(), ~p"/api/v1/venues/#{venue.slug}/cart/items", %{
          "item_id" => "not-a-uuid"
        })

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/orders" do
    test "checks out a cash order and returns it", %{venue: venue, item: item} do
      scope = %Scope{org: venue.org, venue: venue, role: :guest}
      {:ok, venue} = Tenants.set_pay_at_counter_enabled(scope, venue, true)

      %{"guest_token" => guest_token} =
        build_conn()
        |> post(~p"/api/v1/venues/#{venue.slug}/cart/items", %{"item_id" => item.id, "qty" => 1})
        |> json_response(200)

      conn =
        post(build_conn(), ~p"/api/v1/orders", %{
          "venue_slug" => venue.slug,
          "guest_token" => guest_token,
          "payment_method" => "cash"
        })

      assert %{"status" => "pending_payment", "guest_token" => ^guest_token, "total" => total} =
               json_response(conn, 201)

      assert total["amount"] != nil
    end

    test "checks out a wallet order and enqueues the charge", %{venue: venue, item: item} do
      venue = charges_enabled_venue_fixture(venue)

      %{"guest_token" => guest_token} =
        build_conn()
        |> post(~p"/api/v1/venues/#{venue.slug}/cart/items", %{"item_id" => item.id, "qty" => 1})
        |> json_response(200)

      conn =
        post(build_conn(), ~p"/api/v1/orders", %{
          "venue_slug" => venue.slug,
          "guest_token" => guest_token,
          "wallet_msisdn" => "252611111111"
        })

      assert %{"status" => "pending_payment"} = json_response(conn, 201)
      assert_enqueued(worker: ChargeOrder)
    end

    test "an empty cart is a clean 422, not a crash", %{venue: venue} do
      conn =
        post(build_conn(), ~p"/api/v1/orders", %{
          "venue_slug" => venue.slug,
          "guest_token" => Ordering.Cart.generate_guest_token()
        })

      assert json_response(conn, 422)
    end
  end

  describe "GET /api/v1/orders/:guest_token" do
    test "returns the order's live status", %{venue: venue, item: item} do
      scope = %Scope{org: venue.org, venue: venue, role: :guest}
      {:ok, venue} = Tenants.set_pay_at_counter_enabled(scope, venue, true)

      %{"guest_token" => guest_token} =
        build_conn()
        |> post(~p"/api/v1/venues/#{venue.slug}/cart/items", %{"item_id" => item.id, "qty" => 1})
        |> json_response(200)

      post(build_conn(), ~p"/api/v1/orders", %{
        "venue_slug" => venue.slug,
        "guest_token" => guest_token,
        "payment_method" => "cash"
      })

      conn = get(build_conn(), ~p"/api/v1/orders/#{guest_token}")

      assert %{"status" => "pending_payment", "items" => [line]} = json_response(conn, 200)
      assert line["name"] == "Latte"
      assert line["qty"] == 1
    end

    test "404s for an unknown guest_token" do
      conn = get(build_conn(), ~p"/api/v1/orders/does-not-exist")
      assert json_response(conn, 404)
    end
  end
end
