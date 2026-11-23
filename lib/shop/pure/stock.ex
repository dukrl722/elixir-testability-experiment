defmodule Shop.Pure.Stock do
  def required(items) do
    items
    |> Enum.map(fn item -> item.sku end)
    |> Enum.uniq()
    |> Enum.map(fn sku -> {sku, units_of(items, sku)} end)
  end

  def check(needed, available) do
    case Enum.find(needed, fn {sku, quantity} -> Map.get(available, sku, 0) < quantity end) do
      nil -> :ok
      {sku, _quantity} -> {:error, {:out_of_stock, sku}}
    end
  end

  defp units_of(items, sku) do
    items
    |> Enum.filter(fn item -> item.sku == sku end)
    |> Enum.map(fn item -> item.quantity end)
    |> Enum.sum()
  end
end
