# shop

Two versions of the same small order system, written as simply as possible, to
compare how the way the code is organized affects testing in Elixir:

| Variant | Folder | Organization |
| --- | --- | --- |
| pure | `lib/shop/pure/` | The rules (`Pricing`, `Validation`, `Stock`) are pure functions: they only use their arguments. `Orders` is the only module that calls effects. |
| mixed | `lib/shop/mixed/` | The rules call the effects themselves where they need them: `Pricing` reads the clock and `Validation` asks the inventory. |

Both variants expose the same API in their `Orders` module: `process/2`,
`calculate_total/2` and `cancel/2`. Both pass the same acceptance tests.

This is a simplified, didactic version of the experiment in `composition.md`. It
leaves out what that spec requires for a production-style codebase: an umbrella
project, behaviours with Mox, `Decimal`, effect descriptions returned as data,
and `@moduledoc`/`@doc`/`@spec` annotations. `.credo.exs` turns off the credo
rule that asks for a `@moduledoc` in every module.

## Main ideas

- **Money is an integer number of cents.** `1050` means 10.50, so no decimal
  library is needed.
- **Effects are a map of functions** (`Shop.Effects`): `now`, `stock`, `reserve`,
  `release`, `charge` and `notify`. Every API function receives this map. Tests
  pass the same map with some functions swapped for fake ones, so no mock
  library is needed:

  ```elixir
  effects = Shop.Effects.real(%{"SKU-A" => 10})
  Shop.Pure.Orders.process(order, effects)

  # in a test: a payment that is always declined
  effects = Map.put(effects, :charge, fn _customer_id, _amount -> :declined end)
  ```

## Layout

```
lib/shop/
  item.ex, order.ex   the two structs
  effects.ex          the real effects (in-memory stock, payment simulator)
  pure/               pricing.ex, validation.ex, stock.ex, orders.ex
  mixed/              pricing.ex, validation.ex, orders.ex
test/
  acceptance_test.exs the same 42 tests, run once for each variant
  pure/, mixed/       each variant's own tests
  support/            helpers, StreamData generators, metrics formatter
defects/              10 seeded bugs, one patch per variant
scripts/              demo, mutation testing, defect checks, metrics
results/              generated CSV files
```

## Functional programming in the code

| Concept | Example |
| --- | --- |
| Functions passed as arguments | `Enum.all?(order.items, &valid_item?/1)` in `Validation`; every effect in `effects` is a function passed to `process/2` |
| Named and anonymous functions | `def`/`defp` everywhere; `fn item -> item.quantity end` in `Pricing` and `Stock` |
| Pattern matching | the three clauses of `shipping/2`; the four clauses of `cancel/2`; `case` on the payment result in `Orders` |
| Recursion | `reserve/3` in both `Orders` modules goes through the list with `[first | rest]` |
| Collection processing | `Stock.required/1`: `Enum.map`, `Enum.uniq`, `Enum.filter`, `Enum.sum` chained with `|>` |

## Running it

Tested with Elixir 1.20.3 and Erlang/OTP 29. The scripts use the built-in `JSON`
module, so the project requires Elixir 1.18 or later.

```bash
mix deps.get
mix test                         # everything
mix test test/acceptance_test.exs
mix test test/pure               # one variant's own tests
mix run scripts/demo.exs         # both variants on sample orders, real effects
```

Quality checks:

```bash
mix format --check-formatted
mix credo --strict
mix dialyzer
```

Experiment scripts:

```bash
mix run --no-start scripts/check_defects.exs --acceptance   # every patch applies, reverts and is caught
mix run --no-start scripts/mutate.exs --variant pure        # mutation testing of one variant
mix run --no-start scripts/collect_metrics.exs              # everything below, into results/
```

A full metrics run takes a few minutes, most of it mutation testing.

## Business rules

1. Subtotal: sum of `quantity × price`.
2. Bulk discount: 5% when the order has 10 or more units in total.
3. Coupons: `SAVE10` gives 10% off, `FREESHIP` removes shipping, and any other
   coupon is `{:error, :invalid_coupon}`. Discounts do not stack: the largest one wins.
4. Shipping by the first digit of the zip code: `0`-`3` costs 15.00, `4`-`6`
   costs 25.00, `7`-`9` costs 35.00. Free when the discounted subtotal is above
   300.00. A zip code must have 5 to 8 digits.
5. Happy hour: orders created from 00:00 to 05:59 UTC get 5.00 off, and the
   total never goes below zero.
6. Stock: repeated products are added up. Not enough units is
   `{:error, {:out_of_stock, sku}}`.
7. Payment: `:declined` and `{:error, reason}` both release the reserved stock.
8. Notification: sent after the payment. A failure is logged and the order stays paid.
9. `process/2` only accepts `:new` orders. `cancel/2` cancels `:new` and
   `:reserved` orders (releasing the stock) and refuses `:paid` and `:cancelled` ones.

The discounted subtotal is rounded to cents (half up) before shipping is added.

## Tests

| Suite | Where | What it does |
| --- | --- | --- |
| Acceptance | `test/acceptance_test.exs` | 42 tests of the public API, run for each variant (84 in total), with the real effects |
| pure | `test/pure/` | unit tests of the rules with no fake effects at all, plus 5 integration tests of `Orders` |
| mixed | `test/mixed/` | unit tests that pass fake effects to every function that calls one |
| Properties | `property_test.exs` in each folder | the 5 StreamData properties, with shared generators |

Tags: `:acceptance`, `:unit`, `:integration`, `:property`. The ExUnit seed is
fixed (20260101), and so is the payment simulator's.

## Seeded defects

| Defect | Change |
| --- | --- |
| `01_bulk_discount_threshold` | bulk discount from 9 units |
| `02_coupon_stacking` | SAVE10 adds up with the bulk discount |
| `03_shipping_region_boundary` | zip codes starting with `3` pay 25.00 |
| `04_free_shipping_base` | free shipping checked against the subtotal before the discount |
| `05_happy_hour_boundary` | happy hour includes 06:00 |
| `06_negative_total` | happy hour can make the total negative |
| `07_stock_not_released_on_error` | stock not released on a gateway error |
| `08_notification_cancels_order` | a notification failure fails the order |
| `09_reserve_before_coupon_check` | the coupon is checked only after the stock is reserved, and the stock is never released |
| `10_early_rounding` | discounted subtotal rounded to whole reais before shipping |

The patches are generated by `bash scripts/make_defects.sh`. Run it again after
changing `pricing.ex` or `orders.ex`, so the patches match the new lines.

`defects_detected` applies each patch and runs the variant's **own** suite
(`test/<variant>`). `results/defects_<variant>.csv` says which ones it caught.

## Mutation testing

`scripts/mutate.exs` changes one thing at a time in `lib/shop/<variant>/*.ex`
and runs the variant's own suite. The mutant is `killed` if a test fails,
`survived` if all pass and `invalid` if it does not compile. Operators:

- `gt_to_gte` / `lt_to_lte`: `>` becomes `>=`, `<` becomes `<=`;
- `plus_to_minus`: `+` becomes `-`;
- `zero_constant`: a numeric module attribute (`@bulk_units 10`) becomes zero;
- `remove_clause`: one clause of a `case`, `cond` or multi-clause function is deleted.

## Metrics (`results/metrics.csv`)

| Column | How it is measured |
| --- | --- |
| `business_loc` | code lines (no blanks, comments or docs) of `lib/shop/<variant>/` |
| `test_loc` | same rule, over `test/<variant>/` |
| `unit_tests`, `integration_tests`, `property_tests` | tests run per tag |
| `mock_count` | fake effect functions written in the variant's own tests (`charge: fn ...`) |
| `line_coverage` | `mix coveralls.json test/<variant>`, % of lines of `lib/shop/<variant>/` |
| `mutation_score` | killed ÷ (killed + survived) |
| `defects_detected` | 0 to 10 |
| `suite_time_ms` | mean ExUnit run time of the own suite over 10 runs |
| `credo_issues` | `mix credo --strict --all`, issues in `lib/shop/<variant>/` |
| `dialyzer_warnings` | `mix dialyzer`, warnings in `lib/shop/<variant>/` |

## Known caveats

- **"SAVE10 never increases the total" is false under these rules.** SAVE10 can
  bring the discounted subtotal from above 300.00 down to 300.00 or less, which
  brings shipping back: one item of 330.00 to region 9 costs 330.00 without the
  coupon and 297.00 + 35.00 = 332.00 with it. The property leaves out orders
  whose subtotal is in that range.
- The mutation operators work on text, so the number of mutants depends partly
  on how the code is written. `results/mutation_<variant>.csv` lists every mutant.
- `mock_count` only counts fake functions written in the test files. The
  helper `effects/2` in `test/support/helpers.ex` also fakes the clock, the
  payment and the notifier for every test that uses it.
