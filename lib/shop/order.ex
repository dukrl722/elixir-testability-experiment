defmodule Shop.Order do
  defstruct id: nil,
            customer_id: nil,
            items: [],
            coupon: nil,
            zip_code: nil,
            status: :new,
            total: nil,
            created_at: nil
end
