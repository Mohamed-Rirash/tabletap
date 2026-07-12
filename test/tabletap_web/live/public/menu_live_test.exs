defmodule TabletapWeb.Public.MenuLiveTest do
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Repo}

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

  test "redirects to / for an unknown slug", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/venues/does-not-exist/menu")
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
end
