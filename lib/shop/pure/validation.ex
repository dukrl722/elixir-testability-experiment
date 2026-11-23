defmodule Shop.Pure.Validation do
  @valid_coupons [nil, "SAVE10", "FREESHIP"]

  def validate_status(%{status: :new}), do: :ok
  def validate_status(%{status: status}), do: {:error, {:invalid_status, status}}

  def validate(order) do
    cond do
      order.items == [] -> {:error, :empty_order}
      not Enum.all?(order.items, &valid_item?/1) -> {:error, :invalid_items}
      order.coupon not in @valid_coupons -> {:error, :invalid_coupon}
      not valid_zip_code?(order.zip_code) -> {:error, :invalid_zip_code}
      true -> :ok
    end
  end

  defp valid_item?(item) do
    is_binary(item.sku) and is_integer(item.quantity) and item.quantity > 0 and
      is_integer(item.price) and item.price >= 0
  end

  # 5 to 8 digits.
  defp valid_zip_code?(zip_code) do
    is_binary(zip_code) and String.match?(zip_code, ~r/^\d{5,8}$/)
  end
end
