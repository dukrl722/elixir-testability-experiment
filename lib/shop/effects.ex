defmodule Shop.Effects do
  @error_rate 0.05
  @decline_rate 0.10

  def real(stock \\ %{}, seed \\ 20_260_101) do
    {:ok, inventory} = Agent.start_link(fn -> stock end)
    :rand.seed(:exsss, {seed, seed, seed})

    %{
      now: fn -> DateTime.utc_now() end,
      stock: fn sku -> Agent.get(inventory, fn units -> Map.get(units, sku, 0) end) end,
      reserve: fn sku, quantity ->
        Agent.get_and_update(inventory, fn units -> take(units, sku, quantity) end)
      end,
      release: fn sku, quantity ->
        Agent.update(inventory, fn units -> put_back(units, sku, quantity) end)
      end,
      charge: fn _customer_id, _amount -> simulate_payment(:rand.uniform()) end,
      notify: fn customer_id, message -> IO.puts("[to #{customer_id}] #{message}") end
    }
  end

  defp take(units, sku, quantity) do
    available = Map.get(units, sku, 0)

    if available >= quantity do
      {:ok, Map.put(units, sku, available - quantity)}
    else
      {{:error, :insufficient_stock}, units}
    end
  end

  defp put_back(units, sku, quantity) do
    Map.put(units, sku, Map.get(units, sku, 0) + quantity)
  end

  defp simulate_payment(roll) when roll < @error_rate, do: {:error, :gateway_timeout}
  defp simulate_payment(roll) when roll < @error_rate + @decline_rate, do: :declined
  defp simulate_payment(_roll), do: :approved
end
