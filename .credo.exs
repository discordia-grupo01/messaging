logger_metadata =
  "config/config.exs"
  |> Config.Reader.read!(env: :prod)
  |> get_in([:logger, :console, :metadata])

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: %{
        enabled: [
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, [metadata_keys: logger_metadata]}
        ],
        disabled: [
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []},
          {Credo.Check.Readability.ModuleDoc, []}
        ]
      }
    }
  ]
}
