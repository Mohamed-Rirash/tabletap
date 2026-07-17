defmodule TabletapWeb.UserLive.RegistrationTest do
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Repo
  alias Tabletap.Tenants.{Membership, Org, Venue}

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Start your free trial"
      assert html =~ "Business name"
      assert html =~ "Log in"
    end

    test "renders TableTap's own chrome, not the Phoenix generator's placeholder header",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "TableTap"
      refute html =~ "phoenixframework.org"
      refute html =~ "github.com/phoenixframework"
      refute html =~ "Get Started"
    end

    test "suppresses the sitewide utility bar — Layouts.app's header is the only chrome",
         %{conn: conn} do
      # The bar lives in the root layout, so only the disconnected render
      # shows it — assert on the plain GET, not the connected LiveView.
      html = conn |> get(~p"/users/register") |> html_response(200)

      refute html =~ ~s(id="utility-bar")

      # Sanity check the selector: the same layout does render the bar on a
      # page that doesn't suppress it, so the refute above can't pass vacuously.
      assert conn |> get(~p"/users/log-in") |> html_response(200) =~ ~s(id="utility-bar")
    end

    test "redirects if already logged in", %{conn: conn} do
      %{conn: conn} = register_and_log_in_owner(%{conn: conn})

      result =
        conn
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/dashboard")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "org signup" do
    test "creates an org, venue, and owner membership, and logs the owner straight in", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      attrs = valid_org_signup_attrs(%{"business_name" => "Cadaani Coffee"})

      form = form(lv, "#registration_form", user: attrs)

      # submit_form/2 alone would skip straight to the native POST without
      # ever firing "save" — fine for login (the account already exists),
      # wrong here (the account doesn't exist until "save" creates it). Fire
      # the LiveView submit first, then follow the trigger-action it sets.
      assert render_submit(form) =~ "phx-trigger-action"
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/dashboard"

      assert [%Org{name: "Cadaani Coffee"}] = Repo.all(Org, skip_org_id: true)
      assert [%Venue{name: "Cadaani Coffee"}] = Repo.all(Venue, skip_org_id: true)
      assert [%Membership{role: :owner, venue_id: nil}] = Repo.all(Membership, skip_org_id: true)
    end

    test "lands a fresh owner on the empty venue dashboard", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      form = form(lv, "#registration_form", user: valid_org_signup_attrs())
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      conn = get(conn, ~p"/dashboard")
      assert html_response(conn, 200) =~ "Your venue is set up"
    end

    test "renders an error for a duplicate email", %{conn: conn} do
      %{user: existing_user} = org_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form",
          user: valid_org_signup_attrs(%{"email" => existing_user.email})
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "renders an error when the password is too short", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form",
          user:
            valid_org_signup_attrs(%{"password" => "short", "password_confirmation" => "short"})
        )
        |> render_submit()

      assert result =~ "should be at least 12 character"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
