defmodule CredentialRotationProbe do
  alias Marshall.Accounts.{Login, User}
  alias Marshall.Compute.{Credentials, Host, HostCredential, Ledger}
  @root "/var/lib/overalls-fleet"

  @spec run(map()) :: :ok
  def run(%{"action" => "migrate"}) do
    Marshall.Operations.Migrate.main()
  end

  def run(%{"action" => "create", "state" => name, "tag" => tag}) do
    host =
      Ledger.create!(Host, :enroll, %{
        name: "rotation-#{Ash.UUID.generate()}",
        architecture: :x86_64,
        machine_id: "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        overhead_cores: 1,
        overhead_memory_bytes: 1_073_741_824
      })

    {:ok, issued} = Credentials.rotate(host.id, 3600)
    [credential] = Ledger.read!(HostCredential, id: issued.id)
    true = tagged?(credential.encrypted_secret, tag)
    user = Ash.Seed.seed!(User, %{email: "rotation-#{Ash.UUID.generate()}@example.test"})
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    {:ok, _, _} = Login.verify(token, user)

    write(name, %{
      credentials: [issued.token],
      host_id: host.id,
      machine_id: host.machine_id,
      user_id: user.id,
      token: token,
      cookie: cookie(user, token)
    })
  end

  def run(%{"action" => "resign-cookie", "source" => source, "state" => name}) do
    state = read(source)
    user = Ash.get!(User, state["user_id"], authorize?: false)
    write(name, Map.put(state, "cookie", cookie(user, state["token"])))
  end

  # @cc [owner:ghuntley,label:verification;security] rotation-retains-encrypted-authority
  # Keyring rollout MUST retain real AshCloak host credentials across three
  # releases. Removing a still-needed key MUST fail closed; no credential/token
  # contents or exception terms may enter diagnostics.
  def run(%{"action" => "missing-old-key", "old" => old, "new" => new}) do
    old_state = read(old)
    new_state = read(new)

    Enum.each(old_state["credentials"], fn token ->
      {:error, :temporarily_unavailable} = Credentials.with_host(token, & &1.id)
    end)

    Enum.each(new_state["credentials"], fn token ->
      {:ok, _} = Credentials.with_host(token, & &1.id)
    end)

    :ok
  end

  defp tagged?(ciphertext, tag) do
    # AshCloak stores its ciphertext as base64 by default; inspect the decoded
    # envelope's tag without returning ciphertext or plaintext in diagnostics.
    ciphertext = Base.decode64!(ciphertext)

    System.fetch_env!("MARSHALL_CLOAK_KEYS")
    |> Marshall.Vault.keyring!()
    |> Enum.any?(fn {_, {module, options}} ->
      options[:tag] == "marshall:#{tag}" and module.can_decrypt?(ciphertext, options)
    end)
  end

  defp cookie(user, token) do
    user = Ash.Resource.set_metadata(user, %{token: token})

    options =
      Plug.Session.init(
        store: :cookie,
        key: "_marshall_key",
        signing_salt: "OrkORZio",
        same_site: "Lax"
      )

    conn = Plug.Test.conn(:get, "https://control.example.test/")

    conn = %{
      conn
      | secret_key_base: Application.fetch_env!(:marshall, MarshallWeb.Endpoint)[:secret_key_base]
    }

    conn = conn |> Plug.Session.call(options) |> Plug.Conn.fetch_session()

    conn =
      conn
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> Plug.Conn.send_resp(200, "")

    conn.resp_cookies["_marshall_key"].value
  end

  defp read(name), do: path(name) |> File.read!() |> JSON.decode!()

  defp write(name, value) do
    :ok = File.write(path(name), JSON.encode!(value), [:exclusive])
    :ok = File.chmod(path(name), 0o600)
  end

  defp path(name) do
    true = is_binary(name) and Regex.match?(~r/\Astate-[a-z-]+\z/, name)
    Path.join(@root, name <> ".json")
  end
end

try do
  request = "/var/lib/overalls-fleet/probe-request.json" |> File.read!() |> JSON.decode!()

  if request["action"] == "missing-old-key" do
    ring = System.fetch_env!("MARSHALL_CLOAK_KEYS") |> JSON.decode!()
    [entry] = Enum.filter(ring, &(&1["id"] == "rotation"))
    # Only this isolated operator starts without the old key; live services retain it.
    System.put_env("MARSHALL_CLOAK_KEYS", JSON.encode!([entry]))
  end

  Application.put_env(:marshall, :operator_mode, true)

  unless request["action"] == "migrate" do
    {:ok, _} = Application.ensure_all_started(:marshall)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT id::text FROM overalls_fleet_fixture", [],
        log: false
      )

    true = OverallsProtocol.uuid?(id)
    true = File.read!("/var/lib/overalls-fleet/fixture-id") == id
  end

  :ok = CredentialRotationProbe.run(request)
  IO.puts("Credential rotation probe passed")
rescue
  error ->
    locations =
      for {CredentialRotationProbe, function, _, location} <- __STACKTRACE__,
          do: "#{function}:#{Keyword.get(location, :line, 0)}"

    IO.puts(
      :stderr,
      "Credential rotation probe failed (#{inspect(error.__struct__)}, #{Enum.join(locations, ",")})"
    )

    System.halt(1)
end
