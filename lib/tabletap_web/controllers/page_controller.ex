defmodule TabletapWeb.PageController do
  use TabletapWeb, :controller

  def home(conn, _params) do
    conn
    |> assign(:hide_utility_bar, true)
    |> render(:home)
  end
end
