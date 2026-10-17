defmodule Marshall.Inference.CredentialsTest do
  use Marshall.DataCase, async: false
  alias Marshall.Compute.Ledger
  alias Marshall.Inference.{Credential, Credentials}

  setup do
    Marshall.ComputeFixtures.host_fixture()
  end

  test "bootstrap retry preserves identity and expiry without another audit record", %{host: host} do
    token = token()
    {:ok, first} = Credentials.ensure(host.id, token, 60)
    assert {:ok, ^first} = Credentials.ensure(host.id, token, 3600)
    assert {:ok, authority} = Credentials.authenticate(token)
    assert authority.host_id == host.id
    assert authority.credential_id == first.credential_id
    assert [%{id: id}] = Ledger.read!(Credential, host_id: host.id)
    assert id == first.credential_id

    assert [%{version_action_name: :ensure, changes: changes}] =
             Ledger.read!(Credential.Version, version_source_id: id)

    refute Map.has_key?(changes, "secret_hash")
    refute Map.has_key?(first, :secret)
  end

  test "changed secret or lost local custody cannot replace active authority", %{host: host} do
    original = token()
    {:ok, first} = Credentials.ensure(host.id, original, 3600)
    wrong_secret = first.credential_id <> "." <> secret()

    assert {:error, :inference_bootstrap_conflict} =
             Credentials.ensure(host.id, wrong_secret, 3600)

    assert {:error, :inference_bootstrap_conflict} = Credentials.ensure(host.id, token(), 3600)
    assert {:ok, _} = Credentials.authenticate(original)
    assert [%{id: id}] = Ledger.read!(Credential, host_id: host.id)
    assert id == first.credential_id
  end

  test "revocation refuses both the retained token and replacement bootstrap", %{host: host} do
    original = token()
    {:ok, _} = Credentials.ensure(host.id, original, 3600)
    assert {:ok, :ok} = Credentials.revoke(host.id)
    assert {:error, :inference_bootstrap_conflict} = Credentials.ensure(host.id, original, 3600)
    assert {:error, :inference_bootstrap_conflict} = Credentials.ensure(host.id, token(), 3600)
    assert {:error, :unauthorized} = Credentials.authenticate(original)
    assert [%{revoked_at: %DateTime{}}] = Ledger.read!(Credential, host_id: host.id)
  end

  # @cc [owner:ghuntley,label:verification;security] ziggy-retired-host-inference-fence
  # The fleet control socket MUST refuse a retired host's inference credential
  # as unauthorized at identity and renew, including on a socket bound before
  # retirement; the domain layer MUST refuse authentication.
  test "a retired host's ziggy credential is fenced at domain and socket axioms", %{host: host} do
    alias OverallsProtocol.Control.Client
    alias Marshall.Inference.Requests
    {:ok, issued} = Credentials.rotate(host.id, 3600)
    token = issued.id <> "." <> issued.secret

    call = fn route, input ->
      Marshall.Control.Services.Ziggy.handle_request("ziggy." <> route, input, %{token: token})
    end

    host_id = host.id
    assert call.("identity", %{"version" => 1}) == {:error, "unsupported_version"}
    assert {:ok, %{"host_id" => ^host_id}} = call.("identity", %{"version" => 2})
    assert {:ok, %{host_id: _}} = Requests.identity(token)

    # The same acceptance MUST arrive over the real fleet control socket.
    client = control_client(listener(MarshallWeb.FleetEndpoint), token, host.id)

    assert {:ok, %{"host_id" => ^host_id}} =
             Client.request(client, "ziggy.identity", %{"version" => 2})

    assert Client.request(client, "ziggy.identity", %{"version" => 1}) ==
             {:error, "unsupported_version"}

    id = Ash.UUID.generate()
    assert {:ok, _} = Marshall.Compute.Drains.request(host.id, id, "test:retire-ziggy")
    assert {:ok, _} = Marshall.Compute.Drains.advance(id)
    assert {:ok, _} = Marshall.Compute.Drains.retire(id)

    # The retained, unrevoked inference credential is fenced solely by the
    # retired host's permanent authority class.
    assert {:error, :unauthorized} = Credentials.authenticate(token)
    assert {:error, :unauthorized} = Requests.identity(token)
    assert {:error, :unauthorized} = Requests.renew(token, Ash.UUID.generate())
    assert call.("identity", %{"version" => 2}) == {:error, "unauthorized"}

    assert call.("renew", %{"version" => 2, "request_id" => Ash.UUID.generate()}) ==
             {:error, "unauthorized"}

    assert Client.request(client, "ziggy.identity", %{"version" => 2}) == {:error, "unauthorized"}

    assert Client.request(client, "ziggy.renew", %{
             "version" => 2,
             "request_id" => Ash.UUID.generate()
           }) == {:error, "unauthorized"}
  end

  test "expired authority cannot acquire a fresh bootstrap lifetime", %{host: host} do
    secret = secret()

    existing =
      Ledger.create!(Credential, :issue, %{
        host_id: host.id,
        secret_hash: :crypto.hash(:sha256, secret),
        expires_at: DateTime.add(Ledger.now(), -1)
      })

    original = existing.id <> "." <> secret
    before = Ledger.read!(Credential, host_id: host.id)
    assert {:error, :inference_bootstrap_conflict} = Credentials.ensure(host.id, original, 3600)
    assert {:error, :inference_bootstrap_conflict} = Credentials.ensure(host.id, token(), 3600)
    assert before == Ledger.read!(Credential, host_id: host.id)
  end

  test "disabled and mismatched hosts cannot acquire bootstrap authority", %{host: host} do
    original = token()
    {:ok, _} = Credentials.ensure(host.id, original, 3600)
    other = Marshall.ComputeFixtures.host_fixture().host
    assert {:error, :inference_bootstrap_conflict} = Credentials.ensure(other.id, original, 3600)
    assert [] = Ledger.read!(Credential, host_id: other.id)
    Ledger.update!(other, :configure, %{enabled: false})
    assert {:error, :inference_disabled} = Credentials.ensure(other.id, token(), 3600)
    assert [] = Ledger.read!(Credential, host_id: other.id)
  end

  test "malformed bootstrap and ordinary user resource access have no effect", %{host: host} do
    assert {:error, :invalid_inference_bootstrap} = Credentials.ensure(host.id, "invalid", 3600)
    assert {:error, :invalid_inference_bootstrap} = Credentials.ensure(host.id, token(), 0)
    assert {:error, :invalid_inference_bootstrap} = Credentials.ensure("invalid", token(), 3600)

    result =
      Credential
      |> Ash.Changeset.for_create(
        :ensure,
        %{
          id: Ash.UUID.generate(),
          host_id: host.id,
          secret_hash: :crypto.strong_rand_bytes(32),
          expires_at: DateTime.add(Ledger.now(), 3600)
        },
        actor: Marshall.ComputeFixtures.user()
      )
      |> Ash.create()

    assert {:error, _} = result
    assert [] = Ledger.read!(Credential, host_id: host.id)
  end

  @certificate Path.expand("../../fixtures/tls/localhost.pem", __DIR__)
  @key Path.expand("../../fixtures/tls/localhost.key", __DIR__)
  @ca Path.expand("../../fixtures/tls/ca.pem", __DIR__)

  # Serves the fleet endpoint over verified loopback HTTPS exactly as the
  # native listener does; never logs credentials.
  defp listener(plug) do
    {:ok, server} =
      Bandit.start_link(
        plug: plug,
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        certfile: @certificate,
        keyfile: @key
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "https://localhost:#{port}"
  end

  @spec control_client(String.t(), String.t(), String.t()) :: pid()
  defp control_client(base_url, token, host_id) do
    client =
      start_supervised!(
        {OverallsProtocol.Control.Client,
         [
           url: base_url,
           service: "ziggy",
           credential: fn -> {:ok, token} end,
           bind: fn -> %{"host_id" => host_id} end,
           cacertfile: @ca,
           owner: self()
         ]}
      )

    assert_receive {:control, ^client, {:connected, _}}, 5_000
    client
  end

  defp secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp token, do: Ash.UUID.generate() <> "." <> secret()
end
