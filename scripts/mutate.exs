# Mutation testing of the business modules of each variant (section 6.3).
#
#   elixir scripts/mutate.exs                  # both variants
#   elixir scripts/mutate.exs --variant pure   # a single variant
#   elixir scripts/mutate.exs --list           # print the mutants without running them

Code.require_file("support/common.exs", __DIR__)
Code.require_file("support/mutation.exs", __DIR__)

alias Experiment.{Mutation, Scripts}

if "--list" in System.argv() do
  for variant <- Scripts.variants(),
      file <- Scripts.business_files(variant),
      mutant <- Mutation.mutants(file) do
    IO.puts(
      "#{mutant.file}:#{mutant.line} #{mutant.operator}: #{mutant.original} => #{mutant.mutated}"
    )
  end
else
  Scripts.compile_test_env!()

  for variant <- Scripts.parse_variants(System.argv()) do
    summary = Mutation.run(variant)

    IO.puts(
      "[mutation:#{variant}] killed=#{summary.killed} survived=#{summary.survived} " <>
        "invalid=#{summary.invalid} score=#{summary.score}"
    )
  end
end
