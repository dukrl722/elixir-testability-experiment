defmodule Shop.Mixed.Pricing do
  @bulk_units 10
  @bulk_percent 5
  @coupon_percent 10
  @free_shipping_above 30_000
  @happy_hour_discount 500
  @happy_hour_end 6

  def calculate(order, effects) do
    percent = discount_percent(order)
    discounted = round(subtotal(order.items) * (100 - percent) / 100)
    amount = discounted + shipping(order, discounted)
    apply_happy_hour(amount, order, effects)
  end

  def subtotal(items) do
    items
    |> Enum.map(fn item -> item.price * item.quantity end)
    |> Enum.sum()
  end

  def discount_percent(order) do
    max(bulk_percent(order.items), coupon_percent(order.coupon))
  end

  def shipping(%{coupon: "FREESHIP"}, _discounted), do: 0
  def shipping(_order, discounted) when discounted > @free_shipping_above, do: 0
  def shipping(order, _discounted), do: region_rate(order.zip_code)

  defp bulk_percent(items) do
    units = items |> Enum.map(fn item -> item.quantity end) |> Enum.sum()
    if units >= @bulk_units, do: @bulk_percent, else: 0
  end

  defp coupon_percent("SAVE10"), do: @coupon_percent
  defp coupon_percent(_other), do: 0

  # The shipping rate depends on the first digit of the zip code.
  defp region_rate(zip_code) do
    case String.first(zip_code) do
      digit when digit in ["0", "1", "2", "3"] -> 1500
      digit when digit in ["4", "5", "6"] -> 2500
      _other -> 3500
    end
  end

  # From 00:00 to 05:59 the order gets 5.00 off, without going below zero.
  defp apply_happy_hour(amount, order, effects) do
    created_at = order.created_at || effects.now.()

    if created_at.hour < @happy_hour_end do
      max(amount - @happy_hour_discount, 0)
    else
      amount
    end
  end
end
