alias Shop.{Item, Order}

order = %Order{
  id: "bench",
  customer_id: "customer",
  zip_code: "40000000",
  coupon: "SAVE10",
  items: for(i <- 1..10, do: %Item{sku: "SKU-#{i}", quantity: i, price: 999})
}

effects = Shop.Effects.real()

Benchee.run(
  %{
    "pure" => fn -> Shop.Pure.Orders.calculate_total(order, effects) end,
    "mixed" => fn -> Shop.Mixed.Orders.calculate_total(order, effects) end
  },
  time: 2,
  warmup: 1
)
