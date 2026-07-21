defmodule TabletapWeb.Public.MenuLiveTest do
  use TabletapWeb.ConnCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Feedback, Ordering, Repo, Tenants}
  alias Tabletap.Ordering.OrderStateMachine

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

    %{venue: venue, category: category, item: item, scope: scope}
  end

  defp group_fixture(scope, attrs) do
    {:ok, group} = Catalog.create_modifier_group(scope, attrs)
    group
  end

  defp option_fixture(scope, group, attrs) do
    {:ok, option} = Catalog.create_modifier_option(scope, group, attrs)
    option
  end

  defp attach_fixture(scope, item, group) do
    {:ok, _} = Catalog.attach_group_to_item(scope, item, group)
    :ok
  end

  defp add_item_and_open_cart(lv, item) do
    lv |> element("#item-#{item.id}") |> render_click()
    lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})
    lv |> element("button[phx-click='open_cart']") |> render_click()
  end

  test "redirects to / for an unknown slug", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/venues/does-not-exist/menu")
  end

  test "links the customer PWA manifest (build-plan.md Feature 20)", %{conn: conn, venue: venue} do
    {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

    assert html =~ ~s(rel="manifest" href="/manifest-customer.webmanifest")
  end

  test "shows the venue's active, available items", %{conn: conn, venue: venue, item: item} do
    {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

    assert html =~ venue.name
    assert html =~ item.name
    # Not "$3.50" verbatim — the currency symbol is locale-formatted
    # (venue.locale), only the numeric amount is guaranteed stable here.
    assert html =~ "3.50"
  end

  test "falls back to the default locale when the venue locale has no data for the currency",
       %{conn: conn, venue: venue, scope: scope, category: category} do
    # :ETB has no localized data under :so (the venue default locale) —
    # rendering must fall back to :en instead of raising
    # Localize.CurrencyNotLocalizedError (<.money> in core_components).
    {:ok, _item} =
      Catalog.create_item(scope, category, %{
        "name" => "Shaah",
        "price" => Money.new!(:ETB, "12.50")
      })

    {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

    assert html =~ "Shaah"
    assert html =~ "12.50"
  end

  test "does not show an inactive or unavailable item", %{
    conn: conn,
    venue: venue,
    scope: scope,
    item: item
  } do
    {:ok, _} = Catalog.set_availability(scope, item, false)

    {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

    refute html =~ item.name
  end

  test "updates live when a manager toggles availability", %{
    conn: conn,
    venue: venue,
    scope: scope,
    item: item
  } do
    {:ok, lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")
    assert html =~ item.name

    {:ok, _} = Catalog.set_availability(scope, item, false)
    Phoenix.PubSub.broadcast(Tabletap.PubSub, "venue:#{venue.id}:menu", :menu_updated)

    refute render(lv) =~ item.name
  end

  describe "the honest paused/closed banner (design-qa.md Q2)" do
    test "shows nothing when the venue is open and not paused", %{conn: conn, venue: venue} do
      {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

      refute html =~ "Ordering paused"
      refute html =~ "closed right now"
    end

    test "shows the paused banner when Busy Mode's Pause is active", %{
      conn: conn,
      venue: venue,
      scope: scope
    } do
      {:ok, _} = Tenants.pause_ordering(scope, venue, 20)

      {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

      assert html =~ "Ordering paused — please order at the counter"
    end

    test "shows the closed banner when outside configured opening hours", %{
      conn: conn,
      venue: venue
    } do
      hours =
        for day <- ~w(monday tuesday wednesday thursday friday saturday sunday),
            into: %{},
            do: {day, []}

      {:ok, venue} = venue |> Ecto.Changeset.change(opening_hours: hours) |> Repo.update()

      {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

      # Apostrophe is HTML-escaped by HEEx ("We&#39;re") — match the rest.
      assert html =~ "closed right now — please check back later."
    end

    test "the banner appears live when a manager pauses ordering mid-browse", %{
      conn: conn,
      venue: venue,
      scope: scope
    } do
      {:ok, lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      refute html =~ "Ordering paused"

      {:ok, _} = Tenants.pause_ordering(scope, venue, 20)
      Phoenix.PubSub.broadcast(Tabletap.PubSub, "venue:#{venue.id}:menu", :menu_updated)

      assert render(lv) =~ "Ordering paused — please order at the counter"
    end
  end

  test "a canceled org's venue shows 'temporarily unavailable' instead of the menu (design-qa.md Q29)",
       %{conn: conn, venue: venue, scope: scope} do
    scope.org |> Ecto.Changeset.change(subscription_status: :canceled) |> Repo.update!()

    {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

    assert html =~ "temporarily unavailable"
    refute html =~ "guest-token-carrier"
  end

  test "shows the table number when reached via a scanned QR", %{
    conn: conn,
    scope: scope
  } do
    table = table_fixture(scope, %{"number" => "12"})

    # Walk the real path: the /t/:qr_token controller stashes the table in
    # the session, then redirects here.
    conn = get(conn, ~p"/t/#{table.qr_token}")
    {:ok, _lv, html} = live(conn, redirected_to(conn))

    assert html =~ "Table 12"
  end

  test "shows no table caption when opened directly (no scan)", %{conn: conn, venue: venue} do
    {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")
    refute html =~ "Table "
  end

  test "an archived venue's slug behaves like an unknown one", %{conn: conn, venue: venue} do
    {:ok, _} =
      venue |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update()

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/venues/#{venue.slug}/menu")
  end

  describe "sold-out state" do
    test "shows a Sold out badge and the card isn't clickable when today's limit is exhausted",
         %{conn: conn, venue: venue, scope: scope, item: item} do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 1)
      limit = Catalog.get_daily_limit(scope, item)

      Repo.update_all(from(l in Catalog.DailyItemLimit, where: l.id == ^limit.id),
        set: [sold_qty: 1]
      )

      {:ok, lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

      assert html =~ "Sold out"
      refute has_element?(lv, "#item-#{item.id}[phx-click]")
    end

    test "a not-sold-out item stays clickable", %{conn: conn, venue: venue, item: item} do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      assert has_element?(lv, "#item-#{item.id}[phx-click]")
    end
  end

  describe "item detail sheet" do
    test "opening an item with no groups shows the sheet with just qty/notes", %{
      conn: conn,
      venue: venue,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      html = lv |> element("#item-#{item.id}") |> render_click()

      assert html =~ item.name
      assert has_element?(lv, "#add-to-cart-form")
    end

    test "toggle_option and add_to_cart fail gracefully (not a crash) when no sheet is open",
         %{conn: conn, venue: venue, item: item} do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")

      # Neither event has any legitimate way to fire without an open sheet
      # (no matching DOM element exists), but a stale click from a
      # just-closed sheet — or a forged event — must not crash the process.
      # Proof it's genuinely alive, not just technically alive-but-wedged:
      # the LiveView must still handle a normal, legitimate action right
      # after (Process.alive?/1 alone can't tell a healthy process from
      # one that crashed and got replaced by its supervisor).
      render_click(lv, "toggle_option", %{"group-id" => "bogus", "option-id" => "bogus"})
      render_click(lv, "add_to_cart", %{"notes" => ""})

      html = lv |> element("#item-#{item.id}") |> render_click()
      assert html =~ item.name
      assert has_element?(lv, "#add-to-cart-form")
    end

    test "toggle_option with a group id that isn't part of the open sheet fails gracefully",
         %{conn: conn, venue: venue, scope: scope, item: item} do
      group =
        group_fixture(scope, %{"name" => "Extras", "min_selections" => 0, "max_selections" => 1})

      option =
        option_fixture(scope, group, %{"name" => "Ice", "price_delta" => Money.new!(:USD, "0")})

      :ok = attach_fixture(scope, item, group)

      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()

      # A stale option id from a modifier rule change mid-sheet, or a
      # forged group-id — either way, must not crash.
      render_click(lv, "toggle_option", %{"group-id" => "bogus-group", "option-id" => option.id})
      assert Process.alive?(lv.pid)
    end

    test "a default option is pre-selected without the customer touching anything", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      group =
        group_fixture(scope, %{"name" => "Size", "min_selections" => 1, "max_selections" => 1})

      small =
        option_fixture(scope, group, %{
          "name" => "Small",
          "price_delta" => Money.new!(:USD, "0"),
          "default" => true
        })

      _large =
        option_fixture(scope, group, %{
          "name" => "Large",
          "price_delta" => Money.new!(:USD, "1.00")
        })

      :ok = attach_fixture(scope, item, group)

      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      [line] = only_active_cart(scope).items
      assert [%{id: id}] = line.options
      assert id == small.id
    end

    test "picking a max-1 (radio) option replaces the previous selection", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      group =
        group_fixture(scope, %{"name" => "Size", "min_selections" => 1, "max_selections" => 1})

      small =
        option_fixture(scope, group, %{"name" => "Small", "price_delta" => Money.new!(:USD, "0")})

      large =
        option_fixture(scope, group, %{
          "name" => "Large",
          "price_delta" => Money.new!(:USD, "1.00")
        })

      :ok = attach_fixture(scope, item, group)

      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()

      lv |> render_click("toggle_option", %{"group-id" => group.id, "option-id" => small.id})
      lv |> render_click("toggle_option", %{"group-id" => group.id, "option-id" => large.id})
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      [line] = only_active_cart(scope).items
      assert [%{id: id}] = line.options
      assert id == large.id
    end

    test "a checkbox group can't be pushed past its max_selections", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      group =
        group_fixture(scope, %{"name" => "Extras", "min_selections" => 0, "max_selections" => 2})

      a =
        option_fixture(scope, group, %{"name" => "A", "price_delta" => Money.new!(:USD, "0.50")})

      b =
        option_fixture(scope, group, %{"name" => "B", "price_delta" => Money.new!(:USD, "0.50")})

      c =
        option_fixture(scope, group, %{"name" => "C", "price_delta" => Money.new!(:USD, "0.50")})

      :ok = attach_fixture(scope, item, group)

      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()

      lv |> render_click("toggle_option", %{"group-id" => group.id, "option-id" => a.id})
      lv |> render_click("toggle_option", %{"group-id" => group.id, "option-id" => b.id})
      # At the cap — this third click is ignored, not an error.
      lv |> render_click("toggle_option", %{"group-id" => group.id, "option-id" => c.id})
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      [line] = only_active_cart(scope).items
      ids = MapSet.new(line.options, & &1.id)
      assert ids == MapSet.new([a.id, b.id])
    end

    test "the qty stepper stays within 1..20", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()

      lv |> render_click("dec_qty")
      html = render(lv)
      assert html =~ ~r/>\s*1\s*</

      for _ <- 1..25, do: lv |> render_click("inc_qty")
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      [line] = only_active_cart(scope).items
      assert line.qty == 20
    end

    test "submitting a required group with nothing selected blocks the add and flags it red", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      group =
        group_fixture(scope, %{
          "name" => "Size",
          "min_selections" => 1,
          "max_selections" => 1,
          "required" => true
        })

      _option =
        option_fixture(scope, group, %{"name" => "Small", "price_delta" => Money.new!(:USD, "0")})

      :ok = attach_fixture(scope, item, group)

      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      html = lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      assert html =~ "badge-error"
      assert only_active_cart(scope) == nil
    end

    test "adding to cart shows a success flash and closes the sheet", %{
      conn: conn,
      venue: venue,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      html = lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => "no ice"})

      assert html =~ "Added to cart"
      refute has_element?(lv, "#add-to-cart-form")
    end

    test "an item that sells out between opening the sheet and submitting shows an honest error",
         %{conn: conn, venue: venue, scope: scope, item: item} do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()

      {:ok, _} = Catalog.set_daily_limit(scope, item, 1)
      limit = Catalog.get_daily_limit(scope, item)

      Repo.update_all(from(l in Catalog.DailyItemLimit, where: l.id == ^limit.id),
        set: [sold_qty: 1]
      )

      html = lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      assert html =~ "sold out"
      refute has_element?(lv, "#add-to-cart-form")
    end
  end

  describe "cart sheet" do
    test "the sticky bar appears with the right count and total after adding", %{
      conn: conn,
      venue: venue,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      refute has_element?(lv, "button[phx-click='open_cart']")

      lv |> element("#item-#{item.id}") |> render_click()
      html = lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      assert html =~ "View cart"
      assert html =~ "3.50"
    end

    test "opening the cart shows the line, defaults to dine in", %{
      conn: conn,
      venue: venue,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      html = lv |> element("button[phx-click='open_cart']") |> render_click()

      assert html =~ item.name
      assert has_element?(lv, "button[phx-value-kind='dine_in'].bg-brand")
    end

    test "switching to takeaway persists on the cart", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})
      lv |> element("button[phx-click='open_cart']") |> render_click()

      lv |> render_click("set_kind", %{"kind" => "takeaway"})

      assert only_active_cart(scope).kind == :takeaway
    end

    test "incrementing and decrementing a line's quantity", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})
      lv |> element("button[phx-click='open_cart']") |> render_click()

      [line] = only_active_cart(scope).items
      lv |> render_click("inc_line_qty", %{"id" => line.id})

      assert only_active_cart(scope).items |> hd() |> Map.get(:qty) == 2
    end

    test "decrementing a line below 1 removes it", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})
      lv |> element("button[phx-click='open_cart']") |> render_click()

      [line] = only_active_cart(scope).items
      lv |> render_click("dec_line_qty", %{"id" => line.id})

      assert only_active_cart(scope).items == []
    end

    test "removing a line directly", %{conn: conn, venue: venue, scope: scope, item: item} do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})
      lv |> element("button[phx-click='open_cart']") |> render_click()

      [line] = only_active_cart(scope).items
      html = lv |> element("#cart-line-#{line.id} button", "Remove") |> render_click()

      assert html =~ "cart is empty"
      assert only_active_cart(scope).items == []
    end

    test "a line invalidated by a later modifier-rule change shows the re-add message (Q42)", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      group =
        group_fixture(scope, %{"name" => "Extras", "min_selections" => 0, "max_selections" => 1})

      _option =
        option_fixture(scope, group, %{"name" => "Ice", "price_delta" => Money.new!(:USD, "0")})

      :ok = attach_fixture(scope, item, group)

      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      {:ok, _} =
        Catalog.update_modifier_group(scope, group, %{"min_selections" => 1, "required" => true})

      html = lv |> element("button[phx-click='open_cart']") |> render_click()

      assert html =~ "options changed"
    end
  end

  describe "guest identity (design-qa.md Q13/Q50 groundwork)" do
    test "the first add-to-cart mints a guest_token and pushes a persist_guest_token event", %{
      conn: conn,
      venue: venue,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      assert_push_event(lv, "persist_guest_token", %{max_age: 2_592_000})
    end

    test "a second add-to-cart in the same session does not push another cookie event", %{
      conn: conn,
      venue: venue,
      item: item
    } do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})
      assert_push_event(lv, "persist_guest_token", %{})

      lv |> element("#item-#{item.id}") |> render_click()
      lv |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})
      refute_receive {_ref, {:push_event, "persist_guest_token", _}}, 100
    end

    test "a returning guest with a cookie already set sees their cart rebuilt on a fresh mount",
         %{
           conn: conn,
           venue: venue,
           scope: scope,
           item: item
         } do
      token = Tabletap.Ordering.Cart.generate_guest_token()
      {:ok, _cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)

      conn = Plug.Test.put_req_cookie(conn, "guest_token", token)
      {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

      assert html =~ "View cart"
      assert html =~ "3.50"
    end
  end

  describe "two guests at the same table stay independent (build-plan.md Feature 07 verify step)" do
    test "different guest_token cookies never see each other's cart", %{
      venue: venue,
      scope: scope
    } do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Food"})

      {:ok, burger} =
        Catalog.create_item(scope, category, %{
          "name" => "Burger",
          "price" => Money.new!(:USD, "5.00")
        })

      {:ok, fries} =
        Catalog.create_item(scope, category, %{
          "name" => "Fries",
          "price" => Money.new!(:USD, "2.00")
        })

      conn_a = Phoenix.ConnTest.build_conn()
      conn_b = Phoenix.ConnTest.build_conn()

      {:ok, lv_a, _html} = live(conn_a, ~p"/venues/#{venue.slug}/menu")
      lv_a |> element("#item-#{burger.id}") |> render_click()
      lv_a |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      {:ok, lv_b, _html} = live(conn_b, ~p"/venues/#{venue.slug}/menu")
      lv_b |> element("#item-#{fries.id}") |> render_click()
      lv_b |> element("#add-to-cart-form") |> render_submit(%{"notes" => ""})

      lv_a |> element("button[phx-click='open_cart']") |> render_click()
      lv_b |> element("button[phx-click='open_cart']") |> render_click()

      # Both items are on the shared menu regardless of cart contents, so
      # asserting on whole-page HTML would prove nothing — scope to each
      # cart's own line rows specifically.
      [cart_a, cart_b] =
        Repo.all(
          from(c in Ordering.Cart,
            where: c.venue_id == ^venue.id and c.status == :active,
            preload: [items: :menu_item]
          )
        )

      cart_with_item = fn carts, item ->
        Enum.find(carts, &(hd(&1.items).menu_item.id == item.id))
      end

      cart_a_row = cart_with_item.([cart_a, cart_b], burger)
      cart_b_row = cart_with_item.([cart_a, cart_b], fries)

      [line_a] = cart_a_row.items
      [line_b] = cart_b_row.items

      assert has_element?(lv_a, "#cart-line-#{line_a.id} p", "Burger")
      refute has_element?(lv_a, "#cart-line-#{line_b.id}")
      assert has_element?(lv_b, "#cart-line-#{line_b.id} p", "Fries")
      refute has_element?(lv_b, "#cart-line-#{line_a.id}")
    end
  end

  describe "checkout (build-plan.md Feature 09)" do
    test "shows the honest not-set-up message instead of a payment form when the venue has no charges_enabled",
         %{conn: conn, venue: venue, item: item} do
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      html = add_item_and_open_cart(lv, item)

      # Apostrophe is HTML-escaped by HEEx ("isn&#39;t") — match the rest.
      assert html =~ "set up to accept payments yet"
      refute has_element?(lv, "#checkout-form")
    end

    test "shows the wallet-number checkout form once the venue can accept payments", %{
      conn: conn,
      venue: venue,
      item: item
    } do
      venue = charges_enabled_venue_fixture(venue)
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      add_item_and_open_cart(lv, item)

      assert has_element?(lv, "#checkout-form")
      assert has_element?(lv, "#wallet_msisdn")
    end

    test "placing an order creates a pending payment and redirects to the tracker", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      venue = charges_enabled_venue_fixture(venue)
      {:ok, lv, _html} = live(conn, ~p"/venues/#{venue.slug}/menu")
      add_item_and_open_cart(lv, item)

      assert {:error, {:live_redirect, %{to: to}}} =
               lv
               |> element("#checkout-form")
               |> render_submit(%{"wallet_msisdn" => "252611111111"})

      assert to =~ "/orders/"

      cart = only_active_cart(%{scope | venue: venue})
      assert cart == nil

      payment =
        Repo.one(
          from(p in Tabletap.Payments.Payment,
            where: p.venue_id == ^venue.id,
            order_by: [desc: p.inserted_at]
          )
        )

      assert payment.status == :pending

      assert_enqueued(
        worker: Tabletap.Payments.Workers.ChargeOrder,
        args: %{"payment_id" => payment.id}
      )
    end
  end

  # There's only ever one guest in play per test — fetching by venue
  # avoids reaching into LiveView process internals for the guest_token.
  defp only_active_cart(%Scope{venue: venue}) do
    Repo.one(from(c in Ordering.Cart, where: c.venue_id == ^venue.id and c.status == :active))
    |> case do
      nil -> nil
      cart -> Repo.preload(cart, items: [:menu_item, options: :group])
    end
  end

  @forward_path [:placed, :accepted, :preparing, :ready, :served]

  defp served_order_item(scope, item) do
    token = Ordering.Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)

    order =
      Enum.reduce(@forward_path, order, fn status, acc ->
        {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
        moved
      end)

    [order_item] = Repo.preload(order, :items).items
    {order, order_item}
  end

  describe "rating aggregates (build-plan.md Feature 17)" do
    test "an item with no ratings shows no star line", %{conn: conn, venue: venue, item: item} do
      {:ok, _lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

      assert html =~ item.name
      refute html =~ "hero-star-solid"
    end

    test "shows the live avg + count once an item has ratings", %{
      conn: conn,
      venue: venue,
      scope: scope,
      item: item
    } do
      {order1, order_item1} = served_order_item(scope, item)
      {order2, order_item2} = served_order_item(scope, item)

      {:ok, _} = Feedback.rate_item(scope, order1, order_item1, 5)
      {:ok, lv, html} = live(conn, ~p"/venues/#{venue.slug}/menu")

      assert html =~ "5.0"
      assert html =~ "(1)"

      # A second rating arrives from another customer's tracker while this
      # menu page stays open — the average should update without a reload.
      {:ok, _} = Feedback.rate_item(scope, order2, order_item2, 3)

      html = render(lv)
      assert html =~ "4.0"
      assert html =~ "(2)"
    end
  end
end
