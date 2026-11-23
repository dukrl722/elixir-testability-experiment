%{
  configs: [
    %{
      name: "default",
      checks: %{
        disabled: [
          # The project does not use @moduledoc; the README explains each module.
          {Credo.Check.Readability.ModuleDoc, []}
        ]
      }
    }
  ]
}
