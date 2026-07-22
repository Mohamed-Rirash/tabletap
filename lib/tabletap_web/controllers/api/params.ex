defmodule TabletapWeb.Api.Params do
  @moduledoc """
  A JSON API is the first surface in this codebase exposed to fully
  arbitrary client-supplied ids — every existing LiveView route only
  ever receives an id the app itself generated in a server-rendered
  link. A malformed `:binary_id` string reaching a plain Ecto query
  raises `Ecto.Query.CastError` (an unhandled 500), not a graceful 404.
  Cast first, always, on any `/api/v1` param that flows into a
  `get_*(scope, id)`-shaped context call.
  """

  @doc "Casts a client-supplied id param to a UUID, or `:error`."
  def cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  def cast_uuid(_), do: :error
end
