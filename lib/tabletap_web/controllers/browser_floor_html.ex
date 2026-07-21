defmodule TabletapWeb.BrowserFloorHTML do
  @moduledoc """
  This module contains pages rendered by BrowserFloorController.

  See the `browser_floor_html` directory for all templates available.
  """
  use TabletapWeb, :html

  embed_templates "browser_floor_html/*"
end
