defmodule Shop.Mixed.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Shop.TestHelpers

  alias Shop.Generators
  alias Shop.Mixed.{Orders, Pricing, Validation}

  @moduletag :property

  # The generated orders already have a creation time, so the clock is never read.
  defp total(order), do: Pricing.calculate(order, %{})

  # SAVE10 can push a subtotal from above 300.00 to below it, which brings
  # shipping back. Those orders are left out (see README, "Known caveats").
  defp crosses_free_shipping?(order) do
    subtotal = Generators.subtotal(order)
    subtotal > 30_000 and round(subtotal * 0.9) <= 30_000
  end

  property "total is never negative" do
    check all order <- Generators.order() do
      assert total(order) >= 0
    end
  end

  property "total never exceeds subtotal plus max shipping" do
    check all order <- Generators.order() do
      assert total(order) <= Generators.subtotal(order) + 3500
    end
  end

  property "SAVE10 never increases the total" do
    check all order <- Generators.order(), not crosses_free_shipping?(order) do
      assert total(%{order | coupon: "SAVE10"}) <= total(%{order | coupon: nil})
    end
  end

  property "item order does not change the total" do
    check all order <- Generators.order(), shift <- integer(0..5) do
      {front, back} = Enum.split(order.items, shift)
      assert total(order) == total(%{order | items: Enum.reverse(back ++ front)})
    end
  end

  property "declined payment always releases all reserved stock" do
    check all order <- Generators.order() do
      stock = Map.new(Validation.required_stock(order.items))
      effects = effects(stock, charge: fn _customer_id, _amount -> :declined end)

      assert {:error, :payment_declined} = Orders.process(order, effects)
      assert stock(effects, Map.keys(stock)) == stock
    end
  end
end
