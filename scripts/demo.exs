# Runs both variants on sample orders with the real effects (in-memory stock,
# seeded payment simulator) and prints the results side by side as Markdown
# tables. Amounts are in cents.
#
#   mix run scripts/demo.exs

alias Shop.{Item, Order}

defmodule Demo do
  def item(sku, quantity, price), do: %Item{sku: sku, quantity: quantity, price: price}

  def at(hour), do: DateTime.new!(~D[2026-01-15], Time.new!(hour, 0, 0), "Etc/UTC")

  def order(fields) do
    struct!(
      %Order{
        id: "demo",
        customer_id: "customer-1",
        items: [item("SKU-A", 2, 5000)],
        zip_code: "01310100",
        created_at: at(12)
      },
      fields
    )
  end

  # Fresh real effects with a silent notifier. `payment` forces one outcome;
  # :seeded keeps the simulator (5% errors, 10% declines, fixed seed).
  def effects(stock, payment) do
    effects = Map.put(Shop.Effects.real(stock), :notify, fn _customer_id, _message -> :ok end)

    case payment do
      :seeded -> effects
      :approved -> Map.put(effects, :charge, fn _customer_id, _amount -> :approved end)
      :declined -> Map.put(effects, :charge, fn _customer_id, _amount -> :declined end)
      :error -> Map.put(effects, :charge, fn _customer_id, _amount -> {:error, :timeout} end)
    end
  end

  def show({:ok, %Order{status: status, total: nil}}), do: "ok, #{status}"
  def show({:ok, %Order{status: status, total: total}}), do: "ok, #{status}, #{total}"
  def show({:ok, total}), do: Integer.to_string(total)
  def show({:error, reason}), do: "error: #{inspect(reason)}"

  def stock(effects), do: "A=#{effects.stock.("SKU-A")} B=#{effects.stock.("SKU-B")}"
end

scenarios = [
  {"2 x 50.00, zip 0, 12:00", Demo.order([]), :process, :approved},
  {"SAVE10", Demo.order(coupon: "SAVE10"), :process, :approved},
  {"10 units (bulk 5%)", Demo.order(items: [Demo.item("SKU-A", 10, 1000)]), :process, :approved},
  {"subtotal 320.00, zip 9",
   Demo.order(items: [Demo.item("SKU-A", 1, 32_000)], zip_code: "90000000"), :process, :approved},
  {"FREESHIP, zip 5", Demo.order(coupon: "FREESHIP", zip_code: "50000000"), :process, :approved},
  {"happy hour 02:00", Demo.order(created_at: Demo.at(2)), :process, :approved},
  {"out of stock (SKU-B)",
   Demo.order(items: [Demo.item("SKU-A", 1, 1000), Demo.item("SKU-B", 9, 100)]), :process,
   :approved},
  {"invalid coupon", Demo.order(coupon: "BOGUS"), :process, :approved},
  {"invalid zip code", Demo.order(zip_code: "12-34"), :process, :approved},
  {"payment declined", Demo.order([]), :process, :declined},
  {"gateway error", Demo.order([]), :process, :error},
  {"cancel reserved order", Demo.order(status: :reserved), :cancel, :approved},
  {"cancel paid order", Demo.order(status: :paid), :cancel, :approved}
]

IO.puts(
  "| Scenario | calculate_total | pure: result | pure: stock | mixed: result | mixed: stock |"
)

IO.puts("| --- | --- | --- | --- | --- | --- |")

for {name, order, action, payment} <- scenarios do
  [pure, mixed] =
    for variant <- [Shop.Pure.Orders, Shop.Mixed.Orders] do
      effects = Demo.effects(%{"SKU-A" => 20, "SKU-B" => 5}, payment)
      result = apply(variant, action, [order, effects])
      total = variant.calculate_total(order, effects)
      %{result: Demo.show(result), stock: Demo.stock(effects), total: Demo.show(total)}
    end

  total = if pure.total == mixed.total, do: pure.total, else: "#{pure.total} / #{mixed.total}"

  IO.puts(
    "| #{name} | #{total} | #{pure.result} | #{pure.stock} | #{mixed.result} | #{mixed.stock} |"
  )
end

IO.puts("\n50 identical orders against the payment simulator (5% errors, 10% declines):\n")
IO.puts("| Variant | approved | declined | gateway error | SKU-A left | time (ms) |")
IO.puts("| --- | --- | --- | --- | --- | --- |")

for variant <- [Shop.Pure.Orders, Shop.Mixed.Orders] do
  effects = Demo.effects(%{"SKU-A" => 1000}, :seeded)
  order = Demo.order(items: [Demo.item("SKU-A", 1, 1000)])

  {micros, results} = :timer.tc(fn -> for _ <- 1..50, do: variant.process(order, effects) end)

  approved = Enum.count(results, fn result -> match?({:ok, %Order{status: :paid}}, result) end)
  declined = Enum.count(results, fn result -> result == {:error, :payment_declined} end)
  errors = Enum.count(results, fn result -> match?({:error, {:payment_failed, _}}, result) end)

  IO.puts(
    "| #{inspect(variant)} | #{approved} | #{declined} | #{errors} | " <>
      "#{effects.stock.("SKU-A")} | #{div(micros, 1000)} |"
  )
end
