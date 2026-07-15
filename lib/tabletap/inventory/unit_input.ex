defmodule Tabletap.Inventory.UnitInput do
  @moduledoc """
  Parses a manager's free-typed quantity ("1.5 kg", "500 g", "3") into
  an ingredient's base unit (build-plan.md Feature 12 "unit-conversion
  input helpers") — stock is always stored in base units (`g`/`ml`/
  `piece`, architecture.md); conversion only ever happens at this input
  boundary, never in the ledger or on read.
  """

  @doc """
  Parses `input` against `unit` (an `Ingredient.units/0` value) into the
  equivalent quantity in that base unit. A bare number (no suffix) is
  assumed to already be in the base unit — so "500" for a `:g`
  ingredient is 500 g, not an error. `:piece` has no larger unit to
  convert from; any suffix there is a parse error, not a silently
  ignored one.

  Returns `{:ok, Decimal}` or `:error`.
  """
  def parse(unit, input) when is_binary(input) do
    input |> String.trim() |> String.downcase() |> do_parse(unit)
  end

  def parse(_unit, _input), do: :error

  defp do_parse("", _unit), do: :error

  # Longer/more specific suffix checked first in each branch — "kg"
  # before "g", "ml" before "l" — so e.g. "1.5kg" never gets misread as
  # "1.5k" grams.
  defp do_parse(normalized, :g) do
    with :error <- suffixed(normalized, "kg", 1000),
         :error <- suffixed(normalized, "g", 1) do
      bare(normalized)
    end
  end

  defp do_parse(normalized, :ml) do
    with :error <- suffixed(normalized, "ml", 1),
         :error <- suffixed(normalized, "l", 1000) do
      bare(normalized)
    end
  end

  defp do_parse(normalized, :piece), do: bare(normalized)

  defp suffixed(normalized, suffix, multiplier) do
    if String.ends_with?(normalized, suffix) do
      normalized
      |> String.trim_trailing(suffix)
      |> String.trim()
      |> parse_decimal()
      |> case do
        {:ok, decimal} -> {:ok, Decimal.mult(decimal, multiplier)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp bare(normalized), do: parse_decimal(normalized)

  defp parse_decimal(str) do
    case Decimal.parse(str) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end
end
