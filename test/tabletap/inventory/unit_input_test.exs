defmodule Tabletap.Inventory.UnitInputTest do
  use ExUnit.Case, async: true

  alias Tabletap.Inventory.UnitInput

  describe "parse/2 — grams" do
    test "a bare number is already in the base unit" do
      assert {:ok, qty} = UnitInput.parse(:g, "500")
      assert Decimal.equal?(qty, Decimal.new("500"))
    end

    test "kg converts to grams" do
      assert {:ok, qty} = UnitInput.parse(:g, "1.5kg")
      assert Decimal.equal?(qty, Decimal.new("1500"))
    end

    test "kg with a space and uppercase still parses" do
      assert {:ok, qty} = UnitInput.parse(:g, "1.5 KG")
      assert Decimal.equal?(qty, Decimal.new("1500"))
    end

    test "g suffix is a no-op conversion" do
      assert {:ok, qty} = UnitInput.parse(:g, "500g")
      assert Decimal.equal?(qty, Decimal.new("500"))
    end

    test "negative quantities parse (adjustments/deltas)" do
      assert {:ok, qty} = UnitInput.parse(:g, "-200g")
      assert Decimal.equal?(qty, Decimal.new("-200"))
    end
  end

  describe "parse/2 — milliliters" do
    test "ml is a no-op conversion" do
      assert {:ok, qty} = UnitInput.parse(:ml, "500ml")
      assert Decimal.equal?(qty, Decimal.new("500"))
    end

    test "l converts to ml, not confused with the ml suffix" do
      assert {:ok, qty} = UnitInput.parse(:ml, "1.5l")
      assert Decimal.equal?(qty, Decimal.new("1500"))
    end

    test "a bare number is already ml" do
      assert {:ok, qty} = UnitInput.parse(:ml, "250")
      assert Decimal.equal?(qty, Decimal.new("250"))
    end
  end

  describe "parse/2 — piece" do
    test "a bare number parses" do
      assert {:ok, qty} = UnitInput.parse(:piece, "3")
      assert Decimal.equal?(qty, Decimal.new("3"))
    end

    test "a unit suffix on a piece ingredient is an error" do
      assert :error = UnitInput.parse(:piece, "3kg")
    end
  end

  describe "parse/2 — invalid input" do
    test "empty string" do
      assert :error = UnitInput.parse(:g, "")
    end

    test "garbage text" do
      assert :error = UnitInput.parse(:g, "a lot")
    end

    test "nil input" do
      assert :error = UnitInput.parse(:g, nil)
    end
  end
end
