[
  import_deps: [:ash_state_machine, :ash_postgres, :ash, :reactor, :ecto, :ecto_sql],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,rel,test}/**/*.{ex,exs}"]
]
