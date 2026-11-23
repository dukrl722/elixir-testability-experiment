defmodule Shop.Generators do
  use ExUnitProperties

  alias Shop.{Item, Order}

  def item do
    gen all sku <- member_of(["SKU-A", "SKU-B", "SKU-C", "SKU-D"]),
            quantity <- integer(1..15),
            price <- integer(1..50_000) do
      %Item{sku: sku, quantity: quantity, price: price}
    end
  end

  def zip_code do
    gen all digits <- list_of(integer(0..9), length: 8) do
      Enum.join(digits)
    end
  end

  def order do
    gen all items <- list_of(item(), min_length: 1, max_length: 6),
            coupon <- member_of([nil, "SAVE10", "FREESHIP"]),
            zip_code <- zip_code(),
            hour <- integer(0..23) do
      %Order{
        id: "order-prop",
        customer_id: "customer-prop",
        items: items,
        coupon: coupon,
        zip_code: zip_code,
        created_at: DateTime.new!(~D[2026-01-15], Time.new!(hour, 0, 0), "Etc/UTC")
      }
    end
  end

  def subtotal(order) do
    Enum.reduce(order.items, 0, fn item, sum -> sum + item.price * item.quantity end)
  end
end
