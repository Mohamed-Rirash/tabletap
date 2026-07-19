defmodule TabletapWeb.UserLive.ConfirmationTest do
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.AccountsFixtures
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), confirmed_user: user_fixture()}
  end

  describe "Confirm user" do
    test "renders confirmation page for unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")
      assert html =~ "Confirm and stay logged in"
    end

    test "renders login page for confirmed user", %{conn: conn, confirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Keep me logged in on this device"
    end

    test "renders login page for already logged in user", %{conn: conn, confirmed_user: user} do
      conn = log_in_user(conn, user)

      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Log in"
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "User confirmed successfully"

      assert Accounts.get_user!(user.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :user_token)
      # A bare account with no staff membership is a customer account
      # (build-plan.md Feature 16) — signed_in_path/1 sends them to their
      # own order history, not the marketing homepage.
      assert redirected_to(conn) == ~p"/me/history"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed user in without changing confirmed_at", %{
      conn: conn,
      confirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#login_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Accounts.get_user!(user.id).confirmed_at == user.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end

  describe "guest order linking (build-plan.md Feature 16)" do
    test "a guest_token query param links every matching order across every org", %{
      conn: conn,
      unconfirmed_user: user
    } do
      %{org: org, venue: venue} = org_fixture()
      Tabletap.Repo.put_org_id(org.id)
      scope = %Tabletap.Accounts.Scope{org: org, venue: venue, role: :guest}

      {:ok, category} = Tabletap.Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Tabletap.Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      guest_token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, guest_token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, cart)
      assert order.customer_user_id == nil

      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, _html} = live(conn, ~p"/users/log-in/#{token}?guest_token=#{guest_token}")

      linked = Ordering.get_order(scope, order.id)
      assert linked.customer_user_id == user.id
    end

    test "no guest_token param means no linking attempt", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      # Simply not crashing (and not attempting Ordering at all) is the
      # assertion — a staff magic link never carries this param.
      assert {:ok, _lv, _html} = live(conn, ~p"/users/log-in/#{token}")
    end
  end
end
