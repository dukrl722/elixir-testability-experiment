defmodule Shop.Mixed.ValidationTest do
  use ExUnit.Case, async: true

  import Shop.TestHelpers

  alias Shop.Mixed.Validation

  @moduletag :unit

  describe "validate_status/1" do
    test "only new orders can be processed" do
      assert Validation.validate_status(order()) == :ok

      assert Validation.validate_status(order(status: :paid)) ==
               {:error, {:invalid_status, :paid}}
    end
  end

  describe "validate/1" do
    test "accepts a valid order" do
      assert Validation.validate(order()) == :ok
      assert Validation.validate(order(coupon: "SAVE10")) == :ok
      assert Validation.validate(order(coupon: "FREESHIP")) == :ok
    end

    test "rejects an order without items" do
      assert Validation.validate(order(items: [])) == {:error, :empty_order}
    end

    test "rejects items with a bad quantity or price" do
      for bad <- [item("SKU-A", 0, 100), item("SKU-A", 1.5, 100), item("SKU-A", 1, -1)] do
        assert Validation.validate(order(items: [bad])) == {:error, :invalid_items}
      end
    end

    test "accepts a free item" do
      assert Validation.validate(order(items: [item("SKU-A", 1, 0)])) == :ok
    end

    test "rejects an unknown coupon" do
      assert Validation.validate(order(coupon: "BOGUS")) == {:error, :invalid_coupon}
    end

    test "zip codes have 5 to 8 digits" do
      assert Validation.validate(order(zip_code: "12345")) == :ok
      assert Validation.validate(order(zip_code: "12345678")) == :ok

      for bad <- ["1234", "123456789", "1234A", "", nil] do
        assert Validation.validate(order(zip_code: bad)) == {:error, :invalid_zip_code}
      end
    end
  end

  describe "required_stock/1" do
    test "adds up repeated products, keeping the order of first appearance" do
      items = [item("SKU-B", 1, 100), item("SKU-A", 2, 100), item("SKU-B", 3, 100)]
      assert Validation.required_stock(items) == [{"SKU-B", 4}, {"SKU-A", 2}]
    end
  end

  describe "check_stock/2" do
    test "passes when every product has enough units, even exactly enough" do
      effects = %{stock: fn "SKU-A" -> 2 end}
      assert Validation.check_stock([item("SKU-A", 2, 100)], effects) == :ok
    end

    test "reports the first product without enough units" do
      items = [item("SKU-A", 2, 100), item("SKU-B", 1, 100), item("SKU-C", 9, 100)]
      effects = %{stock: fn sku -> Map.get(%{"SKU-A" => 2, "SKU-C" => 1}, sku, 0) end}

      assert Validation.check_stock(items, effects) == {:error, {:out_of_stock, "SKU-B"}}
    end
  end
end
