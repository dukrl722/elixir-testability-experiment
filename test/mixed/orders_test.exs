defmodule Shop.Mixed.OrdersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Shop.TestHelpers

  alias Shop.Mixed.Orders
  alias Shop.Order

  @moduletag :unit

  # Fake effects that report every call to the test process.
  defp spy_effects(fakes) do
    test_pid = self()

    defaults = %{
      now: fn -> at(12, 0) end,
      stock: fn _sku -> 10 end,
      reserve: fn sku, quantity ->
        send(test_pid, {:reserved, sku, quantity})
        :ok
      end,
      release: fn sku, quantity ->
        send(test_pid, {:released, sku, quantity})
        :ok
      end,
      charge: fn _customer_id, _amount -> :approved end,
      notify: fn _customer_id, _message -> :ok end
    }

    Map.merge(defaults, Map.new(fakes))
  end

  describe "process/2" do
    test "reserves, charges the total and notifies the customer" do
      test_pid = self()

      effects =
        spy_effects(
          now: fn -> at(12, 0) end,
          charge: fn "customer-1", amount ->
            send(test_pid, {:charged, amount})
            :approved
          end,
          notify: fn "customer-1", message ->
            send(test_pid, {:notified, message})
            :ok
          end
        )

      assert {:ok, %Order{status: :paid, total: 2500} = paid} = Orders.process(order(), effects)
      assert paid.created_at == at(12, 0)
      assert_received {:reserved, "SKU-A", 1}
      assert_received {:charged, 2500}
      assert_received {:notified, "Order order-1 confirmed. Total in cents: 2500"}
    end

    test "rejects invalid orders without touching any effect" do
      effects = %{
        now: fn -> at(12, 0) end,
        stock: fn _sku -> flunk("stock should not be read") end,
        reserve: fn _sku, _quantity -> flunk("nothing should be reserved") end,
        charge: fn _customer_id, _amount -> flunk("nothing should be charged") end
      }

      assert {:error, :invalid_coupon} = Orders.process(order(coupon: "BOGUS"), effects)
      assert {:error, :invalid_zip_code} = Orders.process(order(zip_code: "x"), effects)
      assert {:error, :empty_order} = Orders.process(order(items: []), effects)
      assert {:error, {:invalid_status, :paid}} = Orders.process(order(status: :paid), effects)
    end

    test "does not reserve anything when a product is out of stock" do
      effects = spy_effects(stock: fn "SKU-A" -> 0 end)

      assert {:error, {:out_of_stock, "SKU-A"}} = Orders.process(order(), effects)
      refute_received {:reserved, _sku, _quantity}
    end

    test "releases what was reserved when a later reservation fails" do
      test_pid = self()

      effects =
        spy_effects(
          reserve: fn
            "SKU-A", quantity ->
              send(test_pid, {:reserved, "SKU-A", quantity})
              :ok

            "SKU-B", _quantity ->
              {:error, :insufficient_stock}
          end
        )

      order = order(items: [item("SKU-A", 2, 100), item("SKU-B", 1, 100)])

      assert {:error, {:out_of_stock, "SKU-B"}} = Orders.process(order, effects)
      assert_received {:released, "SKU-A", 2}
    end

    test "releases the stock when the payment is declined" do
      effects = spy_effects(charge: fn _customer_id, _amount -> :declined end)

      assert {:error, :payment_declined} = Orders.process(order(), effects)
      assert_received {:released, "SKU-A", 1}
    end

    test "releases the stock on a gateway error" do
      effects = spy_effects(charge: fn _customer_id, _amount -> {:error, :timeout} end)

      assert {:error, {:payment_failed, :timeout}} = Orders.process(order(), effects)
      assert_received {:released, "SKU-A", 1}
    end

    test "logs a failed notification and keeps the order paid" do
      effects = spy_effects(notify: fn _customer_id, _message -> {:error, :down} end)

      log =
        capture_log(fn ->
          assert {:ok, %Order{status: :paid}} = Orders.process(order(), effects)
        end)

      assert log =~ "Failed to notify customer-1"
    end
  end

  describe "calculate_total/2" do
    test "returns the total of a valid order" do
      assert {:ok, 2500} = Orders.calculate_total(order(), %{now: fn -> at(12, 0) end})
    end

    test "rejects an invalid order" do
      assert {:error, :invalid_coupon} =
               Orders.calculate_total(order(coupon: "BOGUS"), %{now: fn -> at(12, 0) end})
    end
  end

  describe "cancel/2" do
    test "cancels a new order without touching the stock" do
      effects = spy_effects([])

      assert {:ok, %Order{status: :cancelled}} = Orders.cancel(order(), effects)
      refute_received {:released, _sku, _quantity}
    end

    test "releases the stock of a reserved order" do
      effects = spy_effects([])
      order = order(status: :reserved, items: [item("SKU-A", 2, 100), item("SKU-A", 1, 100)])

      assert {:ok, %Order{status: :cancelled}} = Orders.cancel(order, effects)
      assert_received {:released, "SKU-A", 3}
    end

    test "refuses paid and cancelled orders" do
      assert {:error, :already_paid} = Orders.cancel(order(status: :paid), %{})
      assert {:error, :already_cancelled} = Orders.cancel(order(status: :cancelled), %{})
    end
  end
end
