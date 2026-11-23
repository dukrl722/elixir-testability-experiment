# Checks that every seeded defect patch applies and reverts cleanly (section 9).
#
#   elixir scripts/check_defects.exs                 # apply/revert check only
#   elixir scripts/check_defects.exs --acceptance    # also confirm the acceptance suite
#                                                    # catches each defect (sanity check)

Code.require_file("support/common.exs", __DIR__)

alias Experiment.Scripts

run_acceptance? = "--acceptance" in System.argv()
if run_acceptance?, do: Scripts.compile_test_env!()

digest = fn files ->
  Map.new(files, &{&1, :crypto.hash(:sha256, File.read!(Path.join(Scripts.root(), &1)))})
end

tracked = Enum.flat_map(Scripts.variants(), &Scripts.business_files/1)

failures =
  for defect <- Scripts.defects(), variant <- Scripts.variants(), reduce: 0 do
    failures ->
      name = Path.basename(defect)
      patch = Path.join(defect, "#{variant}.patch")
      before = digest.(tracked)

      result =
        try do
          if run_acceptance?, do: Scripts.settle()
          Scripts.apply_patch!(patch)

          detected =
            if run_acceptance? do
              {_output, status} =
                System.cmd("mix", ["test", "test/acceptance_test.exs"],
                  cd: Scripts.root(),
                  env: [{"MIX_ENV", "test"}],
                  stderr_to_stdout: true
                )

              if status == 0,
                do: " (NOT caught by acceptance suite)",
                else: " (caught by acceptance suite)"
            else
              ""
            end

          Scripts.revert_patch!(patch)

          if digest.(tracked) == before,
            do: {:ok, "applies and reverts" <> detected},
            else: {:error, "sources differ after revert"}
        rescue
          error -> {:error, Exception.message(error)}
        end

      case result do
        {:ok, message} ->
          IO.puts("ok    #{name}/#{variant}: #{message}")
          failures

        {:error, message} ->
          IO.puts("FAIL  #{name}/#{variant}: #{message}")
          failures + 1
      end
  end

if failures > 0, do: System.halt(1)
