defmodule TabletapWeb.Public.TableHTML do
  @moduledoc """
  Renders `TabletapWeb.Public.TableController`'s honest not-found page.
  """
  use TabletapWeb, :html

  embed_templates "table_html/*"
end
