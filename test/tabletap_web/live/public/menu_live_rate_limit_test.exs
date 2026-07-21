defmodule TabletapWeb.Public.MenuLiveRateLimitTest do
  @moduledoc """
  `add_to_cart`/`place_order` rate limiting (build-plan.md Feature 22) —
  `async: false`, same reasoning as `RateLimiterTest`: the limiter is a
  single shared ETS table. Each test uses its own `x-forwarded-for` IP
  so it never collides with the many other, unrelated `async: true`
  `Public.MenuLive` tests using the default test-conn IP.
  """
  use TabletapWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
  alias Tabletap.Repo
  alias Tabletap.Tenants

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{org: org, venue: venue, item: item}
  end

  defp add_to_cart(lv, item) do
    lv |> element("#item-#{item.id}") |> render_click()
    lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})
  end

  test "the 61st add-to-cart within a minute from the same IP is throttled", %{
    conn: conn,
    venue: venue,
    item: item
  } do
    ip = "203.0.113.#{System.unique_integer([:positive])}"
    conn = Plug.Conn.put_req_header(conn, "x-forwarded-for", ip)
    {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")

    for _ <- 1..60, do: add_to_cart(lv, item)
    refute render(lv) =~ "Please slow down"

    html = add_to_cart(lv, item)
    assert html =~ "Please slow down a little."
  end

  test "the 16th checkout attempt within a minute from the same IP is throttled", %{
    conn: conn,
    org: org,
    venue: venue,
    item: item
  } do
    scope = %Scope{org: org, venue: venue, role: :guest}
    # The checkout form (and its error text) only renders at all when
    # the venue can actually take a payment some way — a fresh venue
    # has neither wallet nor pay-at-counter enabled by default.
    {:ok, venue} = Tenants.set_pay_at_counter_enabled(scope, venue, true)
    {:ok, _venue} = Tenants.pause_ordering(scope, venue, :indefinite)

    guest_token = Cart.generate_guest_token()
    {:ok, _cart} = Ordering.add_to_cart(scope, guest_token, nil, item, [], 1, nil)

    ip = "203.0.113.#{System.unique_integer([:positive])}"

    conn =
      conn
      |> Plug.Conn.put_req_header("x-forwarded-for", ip)
      |> Plug.Test.init_test_session(%{"guest_token" => guest_token})

    {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
    render_click(lv, "open_cart", %{})

    # A paused venue fails checkout the same way on every attempt
    # (never a crash, never a successful navigate-away) — the rate
    # limit is the only thing that changes about the 16th one.
    for _ <- 1..15 do
      html = render_click(lv, "place_order", %{})
      assert html =~ "Ordering is paused"
    end

    html = render_click(lv, "place_order", %{})
    assert html =~ "Please slow down a little."
  end
end
