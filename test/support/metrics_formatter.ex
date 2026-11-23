defmodule Shop.MetricsFormatter do
  use GenServer

  @tags [:unit, :integration, :property]

  @impl true
  def init(_opts) do
    {:ok, %{tests: 0, failures: 0, counts: Map.new(@tags, fn tag -> {tag, 0} end)}}
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: test_state, tags: tags}}, state)
      when test_state == nil or elem(test_state, 0) == :failed do
    counts = Enum.reduce(@tags, state.counts, fn tag, counts -> count(counts, tag, tags) end)
    failures = if test_state == nil, do: state.failures, else: state.failures + 1
    {:noreply, %{state | tests: state.tests + 1, failures: failures, counts: counts}}
  end

  def handle_cast({:suite_finished, %{run: run_us}}, state) do
    lines =
      [tests: state.tests, failures: state.failures, run_us: run_us] ++
        Enum.map(@tags, fn tag -> {tag, state.counts[tag]} end)

    content = Enum.map_join(lines, "\n", fn {key, value} -> "#{key}=#{value}" end)
    File.write!(System.fetch_env!("TEST_METRICS_FILE"), content <> "\n")
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp count(counts, tag, test_tags) do
    if test_tags[tag], do: Map.update!(counts, tag, fn count -> count + 1 end), else: counts
  end
end
