defmodule Shop.TestHelpers do
  alias Shop.{Item, Order}

  def item(sku, quantity, price), do: %Item{sku: sku, quantity: quantity, price: price}

  def order(fields \\ []) do
    struct!(
      %Order{
        id: "order-1",
        customer_id: "customer-1",
        items: [item("SKU-A", 1, 1000)],
        zip_code: "01310100"
      },
      fields
    )
  end

  def at(hour, minute, second \\ 0) do
    DateTime.new!(~D[2026-01-15], Time.new!(hour, minute, second), "Etc/UTC")
  end

  def effects(stock \\ %{"SKU-A" => 100, "SKU-B" => 100}, fakes \\ []) do
    defaults = %{
      now: fn -> at(12, 0) end,
      charge: fn _customer_id, _amount -> :approved end,
      notify: fn _customer_id, _message -> :ok end
    }

    stock
    |> Shop.Effects.real()
    |> Map.merge(defaults)
    |> Map.merge(Map.new(fakes))
  end

  def stock(effects, skus \\ ["SKU-A", "SKU-B"]) do
    Map.new(skus, fn sku -> {sku, effects.stock.(sku)} end)
  end
end
