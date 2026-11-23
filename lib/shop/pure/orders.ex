defmodule Shop.Pure.Orders do
  require Logger

  alias Shop.Pure.{Pricing, Stock, Validation}

  def process(order, effects) do
    order = %{order | created_at: order.created_at || effects.now.()}

    with :ok <- Validation.validate_status(order),
         :ok <- Validation.validate(order),
         :ok <- check_stock(order, effects),
         {:ok, reserved} <- reserve(Stock.required(order.items), [], effects) do
      total = Pricing.total(order, order.created_at.hour)
      charge(%{order | status: :reserved, total: total}, reserved, effects)
    end
  end

  def calculate_total(order, effects) do
    with :ok <- Validation.validate(order) do
      created_at = order.created_at || effects.now.()
      {:ok, Pricing.total(order, created_at.hour)}
    end
  end

  def cancel(%{status: :new} = order, _effects), do: {:ok, %{order | status: :cancelled}}

  def cancel(%{status: :reserved} = order, effects) do
    release(Stock.required(order.items), effects)
    {:ok, %{order | status: :cancelled}}
  end

  def cancel(%{status: :paid}, _effects), do: {:error, :already_paid}
  def cancel(%{status: :cancelled}, _effects), do: {:error, :already_cancelled}

  defp check_stock(order, effects) do
    needed = Stock.required(order.items)
    available = Map.new(needed, fn {sku, _quantity} -> {sku, effects.stock.(sku)} end)
    Stock.check(needed, available)
  end

  # Reserves the first product, then calls itself with the rest of the list.
  # If a reservation fails, the products already reserved go back.
  defp reserve([], reserved, _effects), do: {:ok, reserved}

  defp reserve([{sku, quantity} | rest], reserved, effects) do
    case effects.reserve.(sku, quantity) do
      :ok -> reserve(rest, [{sku, quantity} | reserved], effects)
      {:error, _reason} -> release_and_fail(reserved, {:out_of_stock, sku}, effects)
    end
  end

  defp charge(order, reserved, effects) do
    case effects.charge.(order.customer_id, order.total) do
      :approved -> notify(%{order | status: :paid}, effects)
      :declined -> release_and_fail(reserved, :payment_declined, effects)
      {:error, reason} -> release_and_fail(reserved, {:payment_failed, reason}, effects)
    end
  end

  # A failed notification is only logged: the order stays paid.
  defp notify(order, effects) do
    message = "Order #{order.id} confirmed. Total in cents: #{order.total}"

    case effects.notify.(order.customer_id, message) do
      :ok ->
        {:ok, order}

      {:error, reason} ->
        Logger.warning("Failed to notify #{order.customer_id}: #{inspect(reason)}")
        {:ok, order}
    end
  end

  defp release_and_fail(reserved, reason, effects) do
    release(reserved, effects)
    {:error, reason}
  end

  defp release(products, effects) do
    Enum.each(products, fn {sku, quantity} -> effects.release.(sku, quantity) end)
  end
end
