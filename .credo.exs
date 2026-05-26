%{
  configs: [
    %{
      name: "default",
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Readability.PreferImplicitTry, false},
        {Credo.Check.Readability.AliasOrder, false}
      ]
    }
  ]
}
