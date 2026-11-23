#!/usr/bin/env bash
# Regenerates defects/<name>/{pure,mixed}.patch from the current sources.
# Run it after changing lib/shop/*/pricing.ex or orders.ex, then check the
# patches with: mix run --no-start scripts/check_defects.exs --acceptance
#
#   bash scripts/make_defects.sh
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)

P_PRICING=lib/shop/pure/pricing.ex
P_ORDERS=lib/shop/pure/orders.ex
M_PRICING=lib/shop/mixed/pricing.ex
M_ORDERS=lib/shop/mixed/orders.ex

# make <defect> <variant> <file> <perl expression>
make() {
  local defect=$1 variant=$2 file=$3 expr=$4
  mkdir -p "defects/$defect" "$WORK/$defect"
  cp "$file" "$WORK/$defect/new"
  perl -0pi -e "$expr" "$WORK/$defect/new"
  if cmp -s "$file" "$WORK/$defect/new"; then
    echo "NO CHANGE: $defect $variant" >&2; exit 1
  fi
  diff -u --label "a/$file" --label "b/$file" "$file" "$WORK/$defect/new" > "defects/$defect/$variant.patch" || true
}

# Defects 01-06 and 10 change the same text in both pricing modules.
both_pricing() {
  make "$1" pure  $P_PRICING "$2"
  make "$1" mixed $M_PRICING "$2"
}

# Defects 07-09 change the same text in both workflow modules.
both_orders() {
  make "$1" pure  $P_ORDERS "$2"
  make "$1" mixed $M_ORDERS "$2"
}

both_pricing 01_bulk_discount_threshold 's/\@bulk_units 10/\@bulk_units 9/'
both_pricing 02_coupon_stacking 's/max\(bulk_percent\(order\.items\), coupon_percent\(order\.coupon\)\)/bulk_percent(order.items) + coupon_percent(order.coupon)/'
both_pricing 03_shipping_region_boundary 's/\["0", "1", "2", "3"\]/["0", "1", "2"]/; s/\["4", "5", "6"\]/["3", "4", "5", "6"]/'
both_pricing 04_free_shipping_base 's/amount = discounted \+ shipping\(order, discounted\)/amount = discounted + shipping(order, subtotal(order.items))/'
both_pricing 05_happy_hour_boundary 's/hour < \@happy_hour_end/hour <= \@happy_hour_end/'
both_pricing 06_negative_total 's/max\(amount - \@happy_hour_discount, 0\)/amount - \@happy_hour_discount/'
both_pricing 10_early_rounding 's|discounted = round\(subtotal\(order\.items\) \* \(100 - percent\) / 100\)|discounted = round(subtotal(order.items) * (100 - percent) / 10_000) * 100|'

both_orders 07_stock_not_released_on_error 's/\{:error, reason\} -> release_and_fail\(reserved, \{:payment_failed, reason\}, effects\)/{:error, reason} -> {:error, {:payment_failed, reason}}/'
both_orders 08_notification_cancels_order 's/(inspect\(reason\)\}"\)\n)        \{:ok, order\}/$1        {:error, {:notification_failed, reason}}/'
both_orders 09_reserve_before_coupon_check 's/:ok <- Validation\.validate\(order\),/:ok <- Validation.validate(%{order | coupon: nil}),/; s/(\{:ok, reserved\} <- reserve\(.*?, \[\], effects\)) do\n/$1,\n         :ok <- Validation.validate(order) do\n/'

rm -rf "$WORK"
