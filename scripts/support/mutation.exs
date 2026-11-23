defmodule Experiment.Mutation do
  alias Experiment.Scripts

  @operators [
    {:gt_to_gte, ~r/(?<![-|=<>])>(?![=>])/, ">="},
    {:lt_to_lte, ~r/(?<![<])<(?![=<>|-])/, "<="},
    {:plus_to_minus, ~r/(?<![+])\+(?![+])/, "-"},
    {:zero_constant, ~r/^  @[a-z_]+ (?<m>(?!0\b)\d[\d_]*)\s*$/, "0"}
  ]

  @arrow_clause ~r/^(\s+)(\S.*?) ->(.*)$/
  @def_clause ~r/^(\s+)defp? ([a-z_?!]+)\(/

  def mutants(file) do
    source = Scripts.root() |> Path.join(file) |> File.read!()
    lines = source |> Scripts.classify_lines() |> Enum.with_index(1)
    texts = Enum.map(lines, fn {{text, _kind}, _} -> text end)

    for {{text, :code}, number} <- lines,
        mutation <- line_mutations(text, number, texts),
        do: build(file, texts, number, text, mutation)
  end

  defp line_mutations(text, number, texts) do
    replacements =
      for {name, regex, replacement} <- @operators,
          [{start, length} | _] <-
            Regex.scan(regex, text, return: :index, capture: capture(regex)) do
        {name,
         {:replace,
          binary_part(text, 0, start) <>
            replacement <> binary_part(text, start + length, byte_size(text) - start - length)}}
      end

    case clause_span(text, number, texts) do
      nil -> replacements
      {first, last} -> replacements ++ [{:remove_clause, {:remove, first, last}}]
    end
  end

  # Operators with a named group `m` replace only that group.
  defp capture(regex), do: if("m" in Regex.names(regex), do: ["m"], else: :first)

  # Lines spanned by the clause starting at `number`: a `case`/`cond` clause or
  # one clause of a multi-clause function. `nil` when the line starts neither.
  defp clause_span(text, number, texts) do
    cond do
      match = Regex.run(@def_clause, text) ->
        [_, indent, name] = match
        clauses = Enum.count(texts, &(&1 =~ ~r/^\s+defp? #{Regex.escape(name)}\(/))
        if clauses > 1, do: def_span(texts, number, indent)

      match = Regex.run(@arrow_clause, text) ->
        [_, indent, pattern, body] = match

        cond do
          pattern =~ ~r/\bfn\b/ or String.starts_with?(pattern, "#") -> nil
          String.trim(body) != "" -> {number, number}
          true -> {number, block_end(texts, number, indent)}
        end

      true ->
        nil
    end
  end

  defp def_span(texts, number, indent) do
    texts
    |> Enum.with_index(1)
    |> Enum.drop(number - 1)
    |> Enum.take(4)
    |> Enum.reduce_while(nil, fn {line, index}, nil ->
      cond do
        index > number and line =~ ~r/^\s+defp? / -> {:halt, nil}
        line =~ ~r/(,\s|^\s+)do: / -> {:halt, {number, index}}
        line =~ ~r/\sdo$/ -> {:halt, {number, block_end(texts, index, indent) + 1}}
        true -> {:cont, nil}
      end
    end)
  end

  # Last line of the block opened at `number`, i.e. before the next line
  # indented at most as much as `indent`.
  defp block_end(texts, number, indent) do
    texts
    |> Enum.with_index(1)
    |> Enum.drop(number)
    |> Enum.find(fn {line, _} ->
      String.trim(line) != "" and
        byte_size(line) - byte_size(String.trim_leading(line)) <= byte_size(indent)
    end)
    |> case do
      {_line, index} -> index - 1
      nil -> length(texts)
    end
  end

  defp build(file, texts, number, original, {operator, change}) do
    {new_lines, mutated} =
      case change do
        {:replace, line} ->
          {List.replace_at(texts, number - 1, line), String.trim(line)}

        {:remove, first, last} ->
          {Enum.take(texts, first - 1) ++ Enum.drop(texts, last),
           "(removed lines #{first}-#{last})"}
      end

    %{
      file: file,
      line: number,
      operator: operator,
      original: String.trim(original),
      mutated: mutated,
      source: Enum.join(new_lines, "\n")
    }
  end

  def run(variant, opts \\ []) do
    log = Keyword.get(opts, :log, &IO.puts/1)
    mutants = Enum.flat_map(Scripts.business_files(variant), &mutants/1)
    total = length(mutants)
    log.("[mutation:#{variant}] #{total} mutants")

    results =
      mutants
      |> Enum.with_index(1)
      |> Enum.map(fn {mutant, index} ->
        status = run_mutant(variant, mutant)

        log.(
          "[mutation:#{variant}] #{index}/#{total} #{status} " <>
            "#{mutant.file}:#{mutant.line} #{mutant.operator}"
        )

        Map.put(mutant, :status, status)
      end)

    Scripts.write_csv!(
      Path.join(Scripts.root(), "results/mutation_#{variant}.csv"),
      ~w(file line operator original mutated status),
      Enum.map(results, &[&1.file, &1.line, &1.operator, &1.original, &1.mutated, &1.status])
    )

    summary(results)
  end

  defp run_mutant(variant, mutant) do
    path = Path.join(Scripts.root(), mutant.file)
    original = File.read!(path)

    try do
      Scripts.settle()
      File.write!(path, mutant.source)
      result = Scripts.run_suite(variant, ["--max-failures", "1"])

      cond do
        result.compile_error? -> :invalid
        result.status == 0 -> :survived
        true -> :killed
      end
    after
      File.write!(path, original)
    end
  end

  def summary(results) do
    killed = Enum.count(results, &(&1.status == :killed))
    survived = Enum.count(results, &(&1.status == :survived))
    invalid = Enum.count(results, &(&1.status == :invalid))
    valid = killed + survived

    %{
      killed: killed,
      survived: survived,
      invalid: invalid,
      score: if(valid == 0, do: 0.0, else: Float.round(killed / valid, 4))
    }
  end
end
