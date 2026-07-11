defmodule Tabletap.Tenants.Slug do
  @moduledoc """
  Shared slug generation for `Org` and `Venue`. Always suffixes a short
  random tag instead of checking-and-retrying for uniqueness — cheap,
  collision-proof in practice, and never leaks "that name is taken" for a
  competitor's business name.
  """

  @doc """
  Generates a URL-safe slug from `name`, e.g. "Cadaani Coffee" =>
  "cadaani-coffee-a1b2c3".
  """
  def generate(name) when is_binary(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    base = if base == "", do: "venue", else: base

    "#{base}-#{random_tag()}"
  end

  defp random_tag do
    Base.encode32(:crypto.strong_rand_bytes(3), case: :lower, padding: false)
  end
end
