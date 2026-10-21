defmodule BackupCloakProbe do
  @moduledoc "Exercise real Marshall AshCloak custody across an isolated database restore."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{FleetCertificate, FleetCertificateAccount}

  @type request :: %{
          required(:action) => :create | :verify,
          required(:keyring) => Path.t(),
          required(:digest) => Path.t()
        }

  # @cc [owner:ghuntley,label:verification;security;recovery] backup-cloak-decrypt
  # The restore test MUST load real AshCloak resource fields through the
  # restored keyring and isolated PostgreSQL database. Neither secret value nor
  # ciphertext may enter test output or the repository fixture.
  @spec run(request()) :: :ok
  def run(%{action: action, keyring: keyring, digest: digest}) do
    true = File.regular?(keyring)
    :ok = System.put_env("MARSHALL_CLOAK_KEYS", File.read!(keyring))
    Application.put_env(:marshall, :operator_mode, true)

    if action == :create, do: :ok = Marshall.Operations.Migrate.run()

    {:ok, _} = Application.ensure_all_started(:marshall)
    :ok = assert_operator_isolation()

    case action do
      :create -> create(digest)
      :verify -> verify(digest)
    end
  end

  # @cc [owner:ghuntley,label:verification;security;recovery] operator-boot-binds-no-authority
  # An operator-mode boot against a restored historical database MUST bind no
  # listener socket and consume no background work: exactly the persistence,
  # encryption, authorization, PubSub and non-serving Endpoint children start;
  # both endpoint listeners are absent, and Oban normalizes to no queues, no plugins, no stager and a
  # non-leading isolated peer, so no AshOban trigger or queue consumer can run.
  # This pins the ADR-0029/ADR-0070 isolated-restore boundary, including on the
  # boot that reads the restored database.
  @spec assert_operator_isolation() :: :ok
  defp assert_operator_isolation do
    true = Application.get_env(:marshall, :operator_mode) == true

    ids =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(Marshall.Supervisor),
          do: id

    true =
      MapSet.new(ids) ==
        MapSet.new([
          Marshall.Repo,
          Marshall.Vault,
          Marshall.Authorization.Cedar,
          Oban,
          Phoenix.PubSub.Supervisor,
          MarshallWeb.Endpoint
        ])

    true = is_pid(Process.whereis(MarshallWeb.Endpoint))
    false = MarshallWeb.Endpoint.config(:server)
    {:error, :no_server_found} = MarshallWeb.Endpoint.server_info(:http)
    {:error, :no_server_found} = MarshallWeb.Endpoint.server_info(:https)

    oban = Oban.config()
    [] = oban.queues
    [] = oban.plugins
    false = oban.stager
    {Oban.Peers.Isolated, peer_options} = oban.peer
    false = Keyword.get(peer_options, :leader?)

    IO.puts("Marshall operator isolation verified")
    :ok
  end

  @spec create(Path.t()) :: :ok
  defp create(digest) do
    account_key = :crypto.strong_rand_bytes(32)
    request_key = "fixture-request-" <> Base.encode64(:crypto.strong_rand_bytes(32))
    chain = "fixture-chain-" <> Base.encode64(:crypto.strong_rand_bytes(32))
    csr = :crypto.strong_rand_bytes(64)

    account =
      Ledger.create!(FleetCertificateAccount, :register, %{
        issuer_url: "https://backup-fixture.example.test/directory",
        thumbprint: String.duplicate("a", 43),
        private_key: account_key
      })

    certificate =
      Ledger.create!(FleetCertificate, :enqueue, %{
        generation: 1,
        zone: "apps.example.test"
      })
      |> Ledger.update!(:save_request, %{
        csr_der: csr,
        private_key_pem: request_key,
        csr_fingerprint: hash(csr)
      })
      |> Ledger.update!(:bind_order, %{
        order_url: "https://backup-fixture.example.test/order/1",
        finalize_url: "https://backup-fixture.example.test/finalize/1",
        authorization_url: "https://backup-fixture.example.test/auth/1"
      })
      |> Ledger.update!(:finish_issued, %{
        chain_pem: chain,
        fingerprint: hash(chain),
        expires_at: DateTime.add(Ledger.now(), 86_400)
      })
      |> Ledger.update!(:activate, %{})

    true = account.encrypted_private_key != account_key
    true = certificate.encrypted_private_key_pem != request_key
    true = certificate.encrypted_chain_pem != chain
    true = certificate.encrypted_csr_der != csr

    :ok =
      File.write!(
        digest,
        JSON.encode!(%{
          "account" => hash(account_key),
          "request" => hash(request_key),
          "chain" => hash(chain),
          "csr" => hash(csr)
        }),
        [:exclusive]
      )

    :ok = File.chmod(digest, 0o600)
  end

  @spec verify(Path.t()) :: :ok
  defp verify(digest) do
    expected = digest |> File.read!() |> JSON.decode!()
    [account] = Ledger.read!(FleetCertificateAccount)
    [certificate] = Ledger.read!(FleetCertificate, status: :active)
    account = Ash.load!(account, :private_key, actor: SystemActor.compute())

    certificate =
      Ash.load!(certificate, [:csr_der, :private_key_pem, :chain_pem],
        actor: SystemActor.compute()
      )

    true = hash(account.private_key) == expected["account"]
    true = hash(certificate.private_key_pem) == expected["request"]
    true = hash(certificate.chain_pem) == expected["chain"]
    true = hash(certificate.csr_der) == expected["csr"]
    true = account.encrypted_private_key != account.private_key
    true = certificate.encrypted_private_key_pem != certificate.private_key_pem
    true = certificate.encrypted_chain_pem != certificate.chain_pem
    :ok
  end

  @spec hash(binary()) :: binary()
  defp hash(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

try do
  %{"action" => action, "keyring" => keyring, "digest" => digest} =
    "/run/backup-fixture/cloak-request.json" |> File.read!() |> JSON.decode!()

  true = action in ["create", "verify"]
  true = is_binary(keyring) and Path.type(keyring) == :absolute
  true = is_binary(digest) and Path.type(digest) == :absolute

  request = %{
    action: if(action == "create", do: :create, else: :verify),
    keyring: keyring,
    digest: digest
  }

  :ok = BackupCloakProbe.run(request)
  IO.puts("Marshall Cloak restore probe passed")
rescue
  error ->
    locations =
      for {BackupCloakProbe, function, _, location} <- __STACKTRACE__,
          do: "#{function}:#{Keyword.get(location, :line, 0)}"

    IO.puts(
      :stderr,
      "Marshall Cloak restore probe failed (#{inspect(error.__struct__)}, #{Enum.join(locations, ",")})"
    )

    System.halt(1)
end
