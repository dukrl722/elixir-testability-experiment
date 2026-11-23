defmodule Experiment.Scripts do
  @root Path.expand("../..", __DIR__)

  def root, do: @root

  def variants, do: [:pure, :mixed]

  def business_files(variant) do
    @root
    |> Path.join("lib/shop/#{variant}/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&Path.relative_to(&1, @root))
  end

  def test_dir(variant), do: "test/#{variant}"

  def own_test_files(variant) do
    @root
    |> Path.join("#{test_dir(variant)}/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&Path.relative_to(&1, @root))
  end

  def defects do
    @root |> Path.join("defects/*") |> Path.wildcard() |> Enum.filter(&File.dir?/1) |> Enum.sort()
  end

  def classify_lines(source) do
    {classified, _in_heredoc} =
      source
      |> String.split("\n")
      |> Enum.map_reduce(false, fn line, in_heredoc ->
        trimmed = String.trim(line)
        delimiters = length(String.split(line, ~s("""))) - 1
        toggles = rem(delimiters, 2) == 1

        kind =
          cond do
            in_heredoc or toggles -> :doc
            trimmed == "" -> :blank
            String.starts_with?(trimmed, "#") -> :doc
            Regex.match?(~r/^@(spec|type|typep|callback|doc|moduledoc)\b/, trimmed) -> :doc
            String.starts_with?(trimmed, "| ") -> :doc
            true -> :code
          end

        {{line, kind}, if(toggles, do: not in_heredoc, else: in_heredoc)}
      end)

    classified
  end

  def loc(files) do
    files
    |> Enum.map(fn file ->
      @root
      |> Path.join(file)
      |> File.read!()
      |> classify_lines()
      |> Enum.count(&(elem(&1, 1) == :code))
    end)
    |> Enum.sum()
  end

  def run_suite(variant, extra_args \\ []) do
    metrics_file =
      Path.join(System.tmp_dir!(), "fp_metrics_#{System.unique_integer([:positive])}.txt")

    {output, status} =
      System.cmd("mix", ["test", test_dir(variant) | extra_args],
        cd: @root,
        env: [{"MIX_ENV", "test"}, {"TEST_METRICS_FILE", metrics_file}],
        stderr_to_stdout: true
      )

    metrics = read_metrics(metrics_file)
    File.rm(metrics_file)

    %{
      status: status,
      output: output,
      metrics: metrics,
      compile_error?:
        output =~ ~r/CompileError|SyntaxError|TokenMissingError|== Compilation error/ or
          (status != 0 and metrics == nil)
    }
  end

  defp read_metrics(file) do
    case File.read(file) do
      {:ok, content} ->
        for line <- String.split(content, "\n", trim: true), into: %{} do
          [key, value] = String.split(line, "=", parts: 2)
          {String.to_atom(key), String.to_integer(value)}
        end

      {:error, _} ->
        nil
    end
  end

  def patch(args) do
    System.cmd("patch", ["-p1", "--forward", "--silent", "--no-backup-if-mismatch" | args],
      cd: @root,
      stderr_to_stdout: true
    )
  end

  def apply_patch!(file) do
    case patch(["-i", file]) do
      {_, 0} -> :ok
      {output, _} -> raise "could not apply #{file}:\n#{output}"
    end
  end

  def revert_patch!(file) do
    case patch(["-R", "-i", file]) do
      {_, 0} -> :ok
      {output, _} -> raise "could not revert #{file}:\n#{output}"
    end
  end

  def settle, do: Process.sleep(1_100)

  def compile_test_env! do
    {output, status} =
      System.cmd("mix", ["compile"],
        cd: @root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("compilation failed:\n#{output}")
  end

  def write_csv!(path, header, rows) do
    escape = fn value ->
      value = to_string(value)

      if String.contains?(value, [",", "\"", "\n"]),
        do: ~s("#{String.replace(value, "\"", "\"\"")}"),
        else: value
    end

    lines = Enum.map([header | rows], fn row -> Enum.map_join(row, ",", escape) end)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  def parse_variants(args) do
    case OptionParser.parse(args, strict: [variant: :keep]) do
      {opts, _, _} ->
        case Keyword.get_values(opts, :variant) do
          [] -> variants()
          names -> Enum.map(names, &String.to_existing_atom/1)
        end
    end
  end
end
