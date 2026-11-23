defmodule Shop.Mixed.PricingTest do
  use ExUnit.Case, async: true

  import Shop.TestHelpers

  alias Shop.Mixed.Pricing

  @moduletag :unit

  describe "subtotal/1" do
    test "sums quantity times price" do
      assert Pricing.subtotal([item("SKU-A", 2, 1000), item("SKU-B", 3, 150)]) == 2450
    end
  end

  describe "discount_percent/1" do
    test "no discount below 10 units" do
      assert Pricing.discount_percent(order(items: [item("SKU-A", 9, 100)])) == 0
    end

    test "5% from 10 units, counting all items" do
      order = order(items: [item("SKU-A", 4, 100), item("SKU-B", 6, 100)])
      assert Pricing.discount_percent(order) == 5
    end

    test "SAVE10 gives 10%" do
      assert Pricing.discount_percent(order(coupon: "SAVE10")) == 10
    end

    test "bulk and coupon discounts do not stack" do
      order = order(items: [item("SKU-A", 10, 100)], coupon: "SAVE10")
      assert Pricing.discount_percent(order) == 10
    end
  end

  describe "shipping/2" do
    test "depends on the first digit of the zip code" do
      for {zip_code, expected} <- [
            {"00000000", 1500},
            {"39999999", 1500},
            {"40000000", 2500},
            {"69999999", 2500},
            {"70000000", 3500},
            {"99999999", 3500}
          ] do
        assert Pricing.shipping(order(zip_code: zip_code), 10_000) == expected
      end
    end

    test "is free above 300.00 and with FREESHIP" do
      assert Pricing.shipping(order(), 30_001) == 0
      assert Pricing.shipping(order(), 30_000) == 1500
      assert Pricing.shipping(order(coupon: "FREESHIP"), 1000) == 0
    end
  end

  describe "calculate/2" do
    test "uses the creation time of the order when it has one" do
      effects = %{now: fn -> flunk("the clock should not be read") end}
      assert Pricing.calculate(order(created_at: at(12, 0)), effects) == 2500
    end

    test "reads the clock when the order has no creation time" do
      assert Pricing.calculate(order(), %{now: fn -> at(12, 0) end}) == 2500
    end

    test "takes 5.00 off from 00:00 to 05:59" do
      assert Pricing.calculate(order(), %{now: fn -> at(0, 0) end}) == 2000
      assert Pricing.calculate(order(), %{now: fn -> at(5, 59, 59) end}) == 2000
      assert Pricing.calculate(order(), %{now: fn -> at(6, 0) end}) == 2500
    end

    test "happy hour never makes the total negative" do
      order = order(items: [item("SKU-A", 1, 200)], coupon: "FREESHIP")
      assert Pricing.calculate(order, %{now: fn -> at(3, 0) end}) == 0
    end

    test "free shipping uses the subtotal after the discount" do
      order = order(items: [item("SKU-A", 1, 32_000)], coupon: "SAVE10")
      assert Pricing.calculate(order, %{now: fn -> at(12, 0) end}) == 30_300
    end

    test "rounds the discounted subtotal to cents" do
      order = order(items: [item("SKU-A", 10, 199)])
      assert Pricing.calculate(order, %{now: fn -> at(12, 0) end}) == 3391
    end
  end
end
