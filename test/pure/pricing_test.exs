defmodule Shop.Pure.PricingTest do
  use ExUnit.Case, async: true

  import Shop.TestHelpers

  alias Shop.Pure.Pricing

  @moduletag :unit

  describe "subtotal/1" do
    test "sums quantity times price" do
      assert Pricing.subtotal([item("SKU-A", 2, 1000), item("SKU-B", 3, 150)]) == 2450
    end

    test "is zero for no items" do
      assert Pricing.subtotal([]) == 0
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

    test "FREESHIP gives no percentage discount" do
      assert Pricing.discount_percent(order(coupon: "FREESHIP")) == 0
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

    test "is free above 300.00" do
      order = order(zip_code: "70000000")
      assert Pricing.shipping(order, 30_001) == 0
      assert Pricing.shipping(order, 30_000) == 3500
    end

    test "is free with FREESHIP" do
      assert Pricing.shipping(order(zip_code: "70000000", coupon: "FREESHIP"), 1000) == 0
    end
  end

  describe "apply_happy_hour/2" do
    test "takes 5.00 off from 00:00 to 05:59" do
      assert Pricing.apply_happy_hour(2000, 0) == 1500
      assert Pricing.apply_happy_hour(2000, 5) == 1500
      assert Pricing.apply_happy_hour(2000, 6) == 2000
      assert Pricing.apply_happy_hour(2000, 23) == 2000
    end

    test "never goes below zero" do
      assert Pricing.apply_happy_hour(300, 1) == 0
    end
  end

  describe "total/2" do
    test "adds shipping to the discounted subtotal" do
      order = order(items: [item("SKU-A", 2, 5000)], coupon: "SAVE10")
      assert Pricing.total(order, 12) == 10_500
    end

    test "free shipping uses the subtotal after the discount" do
      order = order(items: [item("SKU-A", 1, 32_000)], coupon: "SAVE10")
      assert Pricing.total(order, 12) == 30_300
    end

    test "rounds the discounted subtotal to cents" do
      assert Pricing.total(order(items: [item("SKU-A", 10, 199)]), 12) == 3391
    end

    test "applies happy hour after shipping" do
      assert Pricing.total(order(), 2) == 2000
    end
  end
end
