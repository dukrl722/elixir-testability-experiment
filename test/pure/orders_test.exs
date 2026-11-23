defmodule Shop.Pure.OrdersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Shop.TestHelpers

  alias Shop.Order
  alias Shop.Pure.Orders

  @moduletag :integration

  test "runs the whole workflow for a valid order" do
    effects = effects(%{"SKU-A" => 5}, now: fn -> at(12, 0) end)

    assert {:ok, %Order{status: :paid, total: 2500} = paid} = Orders.process(order(), effects)
    assert paid.created_at == at(12, 0)
    assert effects.stock.("SKU-A") == 4
  end

  test "does not reserve anything when a product is out of stock" do
    effects = effects(%{"SKU-A" => 0})

    assert {:error, {:out_of_stock, "SKU-A"}} = Orders.process(order(), effects)
  end

  test "releases the stock when the payment is declined" do
    effects = effects(%{"SKU-A" => 5}, charge: fn _customer_id, _amount -> :declined end)

    assert {:error, :payment_declined} = Orders.process(order(), effects)
    assert effects.stock.("SKU-A") == 5
  end

  test "logs a failed notification and keeps the order paid" do
    effects = effects(%{"SKU-A" => 5}, notify: fn _customer_id, _message -> {:error, :down} end)

    log =
      capture_log(fn ->
        assert {:ok, %Order{status: :paid}} = Orders.process(order(), effects)
      end)

    assert log =~ "Failed to notify customer-1"
  end

  test "cancelling a reserved order releases its stock" do
    effects = effects(%{"SKU-A" => 5})

    assert {:ok, %Order{status: :cancelled}} = Orders.cancel(order(status: :reserved), effects)
    assert effects.stock.("SKU-A") == 6
  end
end
