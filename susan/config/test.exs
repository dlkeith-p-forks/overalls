import Config

transport =
  case System.get_env("PGHOST") do
    socket when is_binary(socket) and socket != "" ->
      [socket_dir: socket, username: System.get_env("PGUSER", "postgres")]

    _ ->
      [hostname: "localhost", username: "postgres", password: "postgres"]
  end

config :susan,
       Susan.Repo,
       [
         port: String.to_integer(System.get_env("PGPORT", "5432")),
         database: "susan_test#{System.get_env("MIX_TEST_PARTITION")}",
         pool: Ecto.Adapters.SQL.Sandbox,
         pool_size: System.schedulers_online() * 2
       ] ++ transport

config :susan, Oban, testing: :manual
config :susan, runtime: :test
config :ash, disable_async?: true
config :logger, level: :error
config :susan, provider_http: Susan.FakeProvider
