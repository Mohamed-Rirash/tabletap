defmodule TabletapWeb.BrowserFloorPlugTest do
  @moduledoc """
  design-qa.md Q56's browser floor — a conservative UA sniff confirmed
  with the user to only block unambiguous old-browser cases, erring
  toward letting anything unrecognized through. Exercised via the real
  router/pipeline (`get/2`), not the plug's `call/2` directly, so a
  regression in pipeline ordering (e.g. this plug moved after
  `:fetch_session`) would also be caught.
  """
  use TabletapWeb.ConnCase, async: true

  defp with_user_agent(conn, ua), do: put_req_header(conn, "user-agent", ua)

  test "a modern desktop Chrome passes through", %{conn: conn} do
    conn =
      conn
      |> with_user_agent(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
      )
      |> get(~p"/")

    assert html_response(conn, 200)
  end

  test "an old Chrome (major version below the floor) is redirected", %{conn: conn} do
    conn =
      conn
      |> with_user_agent(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36"
      )
      |> get(~p"/")

    assert redirected_to(conn) == "/unsupported-browser"
  end

  test "Internet Explorer 11 (Trident) is redirected", %{conn: conn} do
    conn =
      conn
      |> with_user_agent("Mozilla/5.0 (Windows NT 10.0; WOW64; Trident/7.0; rv:11.0) like Gecko")
      |> get(~p"/")

    assert redirected_to(conn) == "/unsupported-browser"
  end

  test "iOS 14 Safari (below the iOS 15+ floor) is redirected", %{conn: conn} do
    conn =
      conn
      |> with_user_agent(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 14_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 Mobile/15E148 Safari/604.1"
      )
      |> get(~p"/")

    assert redirected_to(conn) == "/unsupported-browser"
  end

  test "iOS 16 Safari (at/above the floor) passes through", %{conn: conn} do
    conn =
      conn
      |> with_user_agent(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1"
      )
      |> get(~p"/")

    assert html_response(conn, 200)
  end

  test "an unrecognized/unusual user agent passes through untouched (err toward letting through)",
       %{conn: conn} do
    conn = conn |> with_user_agent("SomeObscureBrowser/1.0") |> get(~p"/")

    assert html_response(conn, 200)
  end

  test "no user agent at all passes through untouched", %{conn: conn} do
    conn = conn |> delete_req_header("user-agent") |> get(~p"/")

    assert html_response(conn, 200)
  end

  test "the unsupported-browser page itself never redirect-loops, even for a floored UA", %{
    conn: conn
  } do
    conn =
      conn
      |> with_user_agent("Mozilla/5.0 (Windows NT 10.0; WOW64; Trident/7.0; rv:11.0) like Gecko")
      |> get(~p"/unsupported-browser")

    assert html_response(conn, 200) =~ "Please update your browser"
  end
end
