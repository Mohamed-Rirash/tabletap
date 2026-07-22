defmodule TabletapWeb.ApiShape do
  @moduledoc """
  build-plan.md Feature 23 Commit 6 — "every API response schema
  snapshot-tested." No snapshot-testing library exists in this codebase
  and none is warranted for what's needed here (code-standards.md:
  never add a dependency without checking Phoenix/Elixir already does
  this) — a hand-rolled exact-key-set comparison catches the same class
  of regression a snapshot would (an accidentally added, removed, or
  renamed field), without new tooling.
  """
  import ExUnit.Assertions

  @doc """
  Asserts `actual` (a decoded JSON map/list) has *exactly* the same
  shape as `expected` — same keys at every level, recursively; list
  elements are all checked against the first element's shape. Leaf
  values are never compared, only the key structure.
  """
  def assert_json_shape(actual, expected) when is_map(actual) and is_map(expected) do
    assert Enum.sort(Map.keys(actual)) == Enum.sort(Map.keys(expected)),
           "expected keys #{inspect(Enum.sort(Map.keys(expected)))}, got #{inspect(Enum.sort(Map.keys(actual)))}"

    Enum.each(expected, fn {key, expected_value} ->
      assert_json_shape(Map.fetch!(actual, key), expected_value)
    end)
  end

  def assert_json_shape([], []), do: :ok

  def assert_json_shape(actual, [expected_element]) when is_list(actual) do
    Enum.each(actual, &assert_json_shape(&1, expected_element))
  end

  def assert_json_shape(_actual, _expected), do: :ok
end
