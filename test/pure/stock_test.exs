defmodule Shop.Pure.StockTest do
  use ExUnit.Case, async: true

  import Shop.TestHelpers

  alias Shop.Pure.Stock

  @moduletag :unit

  describe "required/1" do
    test "adds up repeated products, keeping the order of first appearance" do
      items = [item("SKU-B", 1, 100), item("SKU-A", 2, 100), item("SKU-B", 3, 100)]
      assert Stock.required(items) == [{"SKU-B", 4}, {"SKU-A", 2}]
    end
  end

  describe "check/2" do
    test "passes when every product has enough units, even exactly enough" do
      assert Stock.check([{"SKU-A", 2}, {"SKU-B", 1}], %{"SKU-A" => 2, "SKU-B" => 5}) == :ok
    end

    test "reports the first product without enough units" do
      needed = [{"SKU-A", 2}, {"SKU-B", 1}, {"SKU-C", 9}]

      assert Stock.check(needed, %{"SKU-A" => 2, "SKU-C" => 1}) ==
               {:error, {:out_of_stock, "SKU-B"}}
    end
  end
end
