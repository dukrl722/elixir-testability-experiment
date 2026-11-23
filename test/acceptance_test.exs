defmodule Shop.AcceptanceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Shop.TestHelpers

  alias Shop.Order

  @moduletag :acceptance

  setup do
    %{effects: effects()}
  end

  defp assert_total(variant, order, effects, expected) do
    assert {:ok, ^expected} = variant.calculate_total(order, effects)
  end

  for variant <- [Shop.Pure.Orders, Shop.Mixed.Orders] do
    @variant variant

    describe "#{inspect(variant)}" do
      # Subtotal and bulk discount

      test "sums quantity times price and adds shipping", %{effects: effects} do
        order = order(items: [item("SKU-A", 2, 1000), item("SKU-B", 1, 550)])
        assert_total(@variant, order, effects, 4050)
      end

      test "no bulk discount with 9 units", %{effects: effects} do
        assert_total(@variant, order(items: [item("SKU-A", 9, 1000)]), effects, 10_500)
      end

      test "5% bulk discount with exactly 10 units", %{effects: effects} do
        assert_total(@variant, order(items: [item("SKU-A", 10, 1000)]), effects, 11_000)
      end

      test "bulk discount counts units across all items", %{effects: effects} do
        order = order(items: [item("SKU-A", 4, 1000), item("SKU-B", 6, 1000)])
        assert_total(@variant, order, effects, 11_000)
      end

      # Coupons

      test "SAVE10 gives 10% off the subtotal", %{effects: effects} do
        order = order(items: [item("SKU-A", 2, 5000)], coupon: "SAVE10")
        assert_total(@variant, order, effects, 10_500)
      end

      test "SAVE10 does not stack with the bulk discount", %{effects: effects} do
        order = order(items: [item("SKU-A", 10, 1000)], coupon: "SAVE10")
        assert_total(@variant, order, effects, 10_500)
      end

      test "FREESHIP removes shipping", %{effects: effects} do
        order = order(items: [item("SKU-A", 2, 5000)], coupon: "FREESHIP")
        assert_total(@variant, order, effects, 10_000)
      end

      test "FREESHIP keeps the bulk discount", %{effects: effects} do
        order = order(items: [item("SKU-A", 10, 1000)], coupon: "FREESHIP")
        assert_total(@variant, order, effects, 9500)
      end

      test "invalid coupon is rejected", %{effects: effects} do
        assert {:error, :invalid_coupon} =
                 @variant.calculate_total(order(coupon: "BOGUS"), effects)
      end

      # Shipping by region

      test "zip code starting with 0 pays 15.00", %{effects: effects} do
        assert_total(@variant, order(zip_code: "01310100"), effects, 2500)
      end

      test "zip code starting with 3 pays 15.00", %{effects: effects} do
        assert_total(@variant, order(zip_code: "39999999"), effects, 2500)
      end

      test "zip code starting with 4 pays 25.00", %{effects: effects} do
        assert_total(@variant, order(zip_code: "40000000"), effects, 3500)
      end

      test "zip code starting with 6 pays 25.00", %{effects: effects} do
        assert_total(@variant, order(zip_code: "69999999"), effects, 3500)
      end

      test "zip code starting with 7 pays 35.00", %{effects: effects} do
        assert_total(@variant, order(zip_code: "70000000"), effects, 4500)
      end

      test "zip code starting with 9 pays 35.00", %{effects: effects} do
        assert_total(@variant, order(zip_code: "99999999"), effects, 4500)
      end

      test "invalid zip code is rejected", %{effects: effects} do
        assert {:error, :invalid_zip_code} =
                 @variant.calculate_total(order(zip_code: "ABC"), effects)

        assert {:error, :invalid_zip_code} =
                 @variant.calculate_total(order(zip_code: ""), effects)
      end

      # Free shipping by value

      test "free when the discounted subtotal is above 300.00", %{effects: effects} do
        assert_total(@variant, order(items: [item("SKU-A", 1, 30_001)]), effects, 30_001)
      end

      test "paid when the discounted subtotal is exactly 300.00", %{effects: effects} do
        assert_total(@variant, order(items: [item("SKU-A", 1, 30_000)]), effects, 31_500)
      end

      test "uses the subtotal after the discount", %{effects: effects} do
        order = order(items: [item("SKU-A", 1, 32_000)], coupon: "SAVE10")
        assert_total(@variant, order, effects, 30_300)
      end

      # Happy hour

      test "takes 5.00 off orders created at 00:00", %{effects: effects} do
        assert_total(@variant, order(created_at: at(0, 0)), effects, 2000)
      end

      test "takes 5.00 off orders created at 05:59", %{effects: effects} do
        assert_total(@variant, order(created_at: at(5, 59, 59)), effects, 2000)
      end

      test "does not apply at 06:00", %{effects: effects} do
        assert_total(@variant, order(created_at: at(6, 0)), effects, 2500)
      end

      test "never makes the total negative", %{effects: effects} do
        order = order(items: [item("SKU-A", 1, 200)], coupon: "FREESHIP", created_at: at(3, 0))
        assert_total(@variant, order, effects, 0)
      end

      test "uses the clock when the order has no creation time" do
        effects = effects(%{}, now: fn -> at(4, 30) end)
        assert_total(@variant, order(), effects, 2000)
      end

      # Rounding

      test "rounds the total to cents", %{effects: effects} do
        assert_total(@variant, order(items: [item("SKU-A", 10, 199)]), effects, 3391)
      end

      test "keeps the cents of the subtotal", %{effects: effects} do
        assert_total(@variant, order(items: [item("SKU-A", 1, 1099)]), effects, 2599)
      end

      # process/2

      test "process pays the order and reserves the stock", %{effects: effects} do
        order = order(items: [item("SKU-A", 2, 1000), item("SKU-B", 3, 100)])

        assert {:ok, %Order{status: :paid, total: 3800} = paid} = @variant.process(order, effects)
        assert paid.created_at == at(12, 0)
        assert stock(effects) == %{"SKU-A" => 98, "SKU-B" => 97}
      end

      test "process charges the customer the computed total" do
        test_pid = self()

        effects =
          effects(%{"SKU-A" => 100},
            charge: fn customer_id, amount ->
              send(test_pid, {:charged, customer_id, amount})
              :approved
            end
          )

        assert {:ok, _paid} = @variant.process(order(items: [item("SKU-A", 1, 1099)]), effects)
        assert_received {:charged, "customer-1", 2599}
      end

      test "process notifies the customer after payment" do
        test_pid = self()

        effects =
          effects(%{"SKU-A" => 100},
            notify: fn customer_id, message ->
              send(test_pid, {:notified, customer_id, message})
              :ok
            end
          )

        assert {:ok, _paid} = @variant.process(order(), effects)
        assert_received {:notified, "customer-1", message}
        assert message =~ "order-1"
      end

      test "process keeps the creation time already set on the order", %{effects: effects} do
        assert {:ok, paid} = @variant.process(order(created_at: at(5, 0)), effects)
        assert paid.created_at == at(5, 0)
        assert paid.total == 2000
      end

      test "process fails when a product is out of stock", %{effects: effects} do
        order = order(items: [item("SKU-A", 1, 1000), item("SKU-B", 101, 100)])

        assert {:error, {:out_of_stock, "SKU-B"}} = @variant.process(order, effects)
        assert stock(effects) == %{"SKU-A" => 100, "SKU-B" => 100}
      end

      test "process adds up repeated products when checking stock", %{effects: effects} do
        order = order(items: [item("SKU-A", 60, 100), item("SKU-A", 41, 100)])

        assert {:error, {:out_of_stock, "SKU-A"}} = @variant.process(order, effects)
        assert stock(effects) == %{"SKU-A" => 100, "SKU-B" => 100}
      end

      test "process releases the stock when the payment is declined" do
        effects = effects(%{"SKU-A" => 100}, charge: fn _customer_id, _amount -> :declined end)

        assert {:error, :payment_declined} = @variant.process(order(), effects)
        assert stock(effects, ["SKU-A"]) == %{"SKU-A" => 100}
      end

      test "process releases the stock on a gateway error" do
        effects =
          effects(%{"SKU-A" => 100}, charge: fn _customer_id, _amount -> {:error, :timeout} end)

        assert {:error, {:payment_failed, :timeout}} = @variant.process(order(), effects)
        assert stock(effects, ["SKU-A"]) == %{"SKU-A" => 100}
      end

      test "process keeps the order paid when the notification fails" do
        effects =
          effects(%{"SKU-A" => 100},
            notify: fn _customer_id, _message -> {:error, :smtp_down} end
          )

        log =
          capture_log(fn ->
            assert {:ok, %Order{status: :paid}} = @variant.process(order(), effects)
          end)

        assert log =~ "smtp_down"
        assert stock(effects, ["SKU-A"]) == %{"SKU-A" => 99}
      end

      test "process with an invalid coupon does not touch the stock", %{effects: effects} do
        assert {:error, :invalid_coupon} = @variant.process(order(coupon: "BOGUS"), effects)
        assert stock(effects) == %{"SKU-A" => 100, "SKU-B" => 100}
      end

      test "process rejects an order without items", %{effects: effects} do
        assert {:error, :empty_order} = @variant.process(order(items: []), effects)
      end

      test "process rejects an order that is not new", %{effects: effects} do
        assert {:error, {:invalid_status, :paid}} =
                 @variant.process(order(status: :paid), effects)
      end

      # cancel/2

      test "cancel cancels a new order", %{effects: effects} do
        assert {:ok, %Order{status: :cancelled}} = @variant.cancel(order(), effects)
      end

      test "cancel releases the stock of a reserved order", %{effects: effects} do
        order = order(status: :reserved, items: [item("SKU-A", 5, 100)])

        assert {:ok, %Order{status: :cancelled}} = @variant.cancel(order, effects)
        assert stock(effects) == %{"SKU-A" => 105, "SKU-B" => 100}
      end

      test "cancel refuses a paid order", %{effects: effects} do
        assert {:error, :already_paid} = @variant.cancel(order(status: :paid), effects)
      end

      test "cancel refuses an order already cancelled", %{effects: effects} do
        assert {:error, :already_cancelled} = @variant.cancel(order(status: :cancelled), effects)
      end
    end
  end
end
