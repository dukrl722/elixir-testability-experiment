# Collects every metric of section 8 into results/metrics.csv.
#
#   elixir scripts/collect_metrics.exs [options]
#
# Options:
#   --variant pure|mixed   only this variant (repeatable; default: both)
#   --runs N               suite runs averaged for suite_time_ms (default: 10)
#   --reuse-mutation       read results/mutation_<variant>.csv instead of re-running mutants
#   --skip-mutation        leave mutation_score empty
#   --skip-dialyzer        leave dialyzer_warnings empty

Code.require_file("support/common.exs", __DIR__)
Code.require_file("support/mutation.exs", __DIR__)

defmodule Experiment.Metrics do
  alias Experiment.{Mutation, Scripts}

  @columns ~w(variant business_loc test_loc unit_tests integration_tests property_tests
              mock_count line_coverage mutation_score defects_detected suite_time_ms
              credo_issues dialyzer_warnings)

  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          variant: :keep,
          runs: :integer,
          reuse_mutation: :boolean,
          skip_mutation: :boolean,
          skip_dialyzer: :boolean
        ]
      )

    variants = Scripts.parse_variants(argv)

    step("compiling (test env)")
    Scripts.compile_test_env!()

    credo = credo_issues()
    dialyzer = if opts[:skip_dialyzer], do: %{}, else: dialyzer_warnings()

    rows =
      for variant <- variants do
        metrics =
          variant
          |> collect(opts)
          |> Map.put(:credo_issues, Map.get(credo, variant, 0))
          |> Map.put(:dialyzer_warnings, Map.get(dialyzer, variant, ""))

        Enum.map(@columns, &Map.get(metrics, String.to_atom(&1), ""))
      end

    path = Path.join(Scripts.root(), "results/metrics.csv")
    Scripts.write_csv!(path, @columns, rows)
    step("wrote #{Path.relative_to(path, Scripts.root())}")
    IO.puts(File.read!(path))
  end

  defp collect(variant, opts) do
    step("#{variant}: test suite")
    suite = Scripts.run_suite(variant)
    if suite.status != 0, do: raise("#{variant} suite fails:\n#{suite.output}")

    test_files = Scripts.own_test_files(variant)

    %{
      variant: variant,
      business_loc: Scripts.loc(Scripts.business_files(variant)),
      test_loc: Scripts.loc(test_files),
      unit_tests: suite.metrics.unit,
      integration_tests: suite.metrics.integration,
      property_tests: suite.metrics.property,
      mock_count: mock_count(test_files),
      line_coverage: line_coverage(variant),
      mutation_score: mutation_score(variant, opts),
      defects_detected: defects_detected(variant),
      suite_time_ms: suite_time_ms(variant, Keyword.get(opts, :runs, 10))
    }
  end

  # Fake effect functions written in the variant's own tests, such as
  # `charge: fn _customer_id, _amount -> :declined end`.
  defp mock_count(test_files) do
    test_files
    |> Enum.map(fn file ->
      source = File.read!(Path.join(Scripts.root(), file))
      length(Regex.scan(~r/\b(now|stock|reserve|release|charge|notify): fn\b/, source))
    end)
    |> Enum.sum()
  end

  defp line_coverage(variant) do
    step("#{variant}: coverage")

    {output, status} =
      System.cmd("mix", ["coveralls.json", Scripts.test_dir(variant)],
        cd: Scripts.root(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("coverage run failed:\n#{output}")

    %{"source_files" => files} =
      Scripts.root() |> Path.join("cover/excoveralls.json") |> File.read!() |> JSON.decode!()

    # Only the variant's own modules count.
    {covered, relevant} =
      files
      |> Enum.filter(&String.starts_with?(&1["name"], "lib/shop/#{variant}/"))
      |> Enum.flat_map(& &1["coverage"])
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce({0, 0}, fn hits, {covered, relevant} ->
        {if(hits > 0, do: covered + 1, else: covered), relevant + 1}
      end)

    Float.round(covered * 100 / relevant, 2)
  end

  defp mutation_score(variant, opts) do
    cond do
      opts[:skip_mutation] ->
        ""

      opts[:reuse_mutation] ->
        [_header | rows] =
          Path.join(Scripts.root(), "results/mutation_#{variant}.csv")
          |> File.read!()
          |> String.split("\n", trim: true)

        rows
        |> Enum.map(&%{status: &1 |> String.split(",") |> List.last() |> String.to_atom()})
        |> Mutation.summary()
        |> Map.fetch!(:score)

      true ->
        step("#{variant}: mutation testing (this takes a few minutes)")
        Mutation.run(variant, log: fn _ -> :ok end).score
    end
  end

  defp defects_detected(variant) do
    step("#{variant}: seeded defects")

    results =
      for defect <- Scripts.defects() do
        patch = Path.join(defect, "#{variant}.patch")
        Scripts.settle()
        Scripts.apply_patch!(patch)

        try do
          result = Scripts.run_suite(variant)
          if result.compile_error?, do: raise("#{patch} does not compile:\n#{result.output}")
          detected = result.status != 0
          IO.puts("    #{Path.basename(defect)}: #{if detected, do: "detected", else: "missed"}")
          {Path.basename(defect), detected}
        after
          Scripts.revert_patch!(patch)
        end
      end

    Scripts.write_csv!(
      Path.join(Scripts.root(), "results/defects_#{variant}.csv"),
      ~w(defect detected),
      Enum.map(results, fn {name, detected} -> [name, detected] end)
    )

    Enum.count(results, &elem(&1, 1))
  end

  defp suite_time_ms(variant, runs) do
    step("#{variant}: timing #{runs} suite runs")
    Scripts.settle()

    times =
      for _ <- 1..runs do
        %{status: 0, metrics: %{run_us: run_us}} = Scripts.run_suite(variant)
        run_us / 1_000
      end

    Float.round(Enum.sum(times) / runs, 2)
  end

  defp credo_issues do
    step("credo")

    {output, _status} =
      System.cmd("mix", ["credo", "--strict", "--all", "--format", "json"],
        cd: Scripts.root(),
        stderr_to_stdout: false
      )

    %{"issues" => issues} = output |> json_payload() |> JSON.decode!()
    count_by_variant(issues, & &1["filename"])
  end

  defp dialyzer_warnings do
    step("dialyzer (the first run builds the PLT and takes a few minutes)")

    {output, _status} =
      System.cmd("mix", ["dialyzer", "--format", "short"],
        cd: Scripts.root(),
        stderr_to_stdout: true
      )

    lines = output |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/^lib\/[^:]+:\d+/))
    count_by_variant(lines, & &1)
  end

  defp count_by_variant(entries, path_fun) do
    Map.new(Scripts.variants(), fn variant ->
      prefix = "lib/shop/#{variant}/"
      {variant, Enum.count(entries, &String.starts_with?(path_fun.(&1), prefix))}
    end)
  end

  # Mix may print compilation output before the JSON document.
  defp json_payload(output) do
    case :binary.match(output, "{") do
      {start, _} -> binary_part(output, start, byte_size(output) - start)
      :nomatch -> raise "unexpected credo output:\n#{output}"
    end
  end

  defp step(message), do: IO.puts("==> #{message}")
end

Experiment.Metrics.run(System.argv())
