# Fixed seed: the test order and every StreamData run are the same on every run.
# TEST_METRICS_FILE is set by scripts/collect_metrics.exs to collect test counts.
formatters =
  if System.get_env("TEST_METRICS_FILE"),
    do: [ExUnit.CLIFormatter, Shop.MetricsFormatter],
    else: [ExUnit.CLIFormatter]

ExUnit.start(seed: 20_260_101, formatters: formatters)
