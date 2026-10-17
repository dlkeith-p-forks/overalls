defmodule Marshall.Compute.CredentialsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Credentials, Host, HostCredential, HostReports, Ledger, Reservation}

  setup do
    host_fixture()
  end

  test "credentials are encrypted and excluded from audit and Inspect", %{host: host} do
    {:ok, issued} = Credentials.rotate(host.id, 3600)
    [credential] = Ledger.read!(HostCredential, id: issued.id)
    check_secret_absent!(inspect(issued), issued.token)
    check_secret_absent!(inspect(credential), credential.encrypted_secret)
    [_, secret] = String.split(issued.token, ":")
    check_secret_absent!(credential.encrypted_secret, secret)
    decrypted? = decrypts_to?(credential, secret)
    assert decrypted?
    assert %Ash.NotLoaded{} = credential.secret
    assert {:ok, id} = Credentials.with_host(issued.token, & &1.id)
    assert id == host.id

    versions = Ledger.read!(HostCredential.Version, version_source_id: issued.id)
    assert [%{version_action_name: :issue, changes: changes}] = versions

    if Map.has_key?(changes, "secret") or Map.has_key?(changes, "encrypted_secret"),
      do: flunk("credential audit unexpectedly includes a secret field")

    check_secret_absent!(inspect(versions), secret)
  end

  test "rotation and revocation invalidate old sessions without releasing reservations", %{
    host: host,
    report: report
  } do
    {:ok, vm} = Marshall.Compute.provision(request(), actor: user())
    {:ok, first} = Credentials.rotate(host.id, 3600)
    {:ok, epoch} = HostReports.connect(host.id)
    assert {:ok, :ok} = HostReports.ingest(host.id, epoch, report)
    {:ok, second} = Credentials.rotate(host.id, 3600)

    assert {:error, :unauthorized} =
             Credentials.with_host(first.token, fn _ -> flunk("revoked credential accepted") end)

    assert {:ok, :ok} = Credentials.with_host(second.token, fn _ -> :ok end)

    assert {:error, :stale_connection} =
             HostReports.ingest(host.id, epoch, %{report | sequence: 2})

    assert [%{reported_at: nil}] = Ledger.read!(Host, id: host.id)
    assert [%{compute_held: true, disk_held: true}] = Ledger.read!(Reservation, vm_id: vm.id)
    assert {:ok, :ok} = Credentials.revoke(host.id)
    assert {:ok, :ok} = Credentials.revoke(host.id)
    assert {:error, :unauthorized} = Credentials.with_host(second.token, fn _ -> :ok end)
    assert [] = Ledger.read!(HostCredential, host_id: host.id)

    history =
      HostCredential |> Ash.Query.for_read(:history) |> Ash.read!(actor: SystemActor.compute())

    assert length(history) == 2
    assert Enum.all?(history, &match?(%DateTime{}, &1.archived_at))
    versions = Ledger.read!(HostCredential.Version)
    assert Enum.count(versions, &(&1.version_action_name == :revoke)) == 2
  end

  test "expired credentials and user access are denied", %{host: host} do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    credential =
      Ledger.create!(HostCredential, :issue, %{
        host_id: host.id,
        secret: secret,
        expires_at: DateTime.add(Ledger.now(), -1, :second)
      })

    assert {:error, :unauthorized} =
             Credentials.with_host(credential.id <> ":" <> secret, fn _ -> :ok end)

    assert {:error, _} = Ash.read(HostCredential, actor: user())
    assert {:error, _} = Ash.read(HostCredential.Version, actor: user())
    assert {:error, _} = HostCredential |> Ash.Query.for_read(:history) |> Ash.read(actor: user())
  end

  test "credential diagnostics are catalogued for rotation, revocation and rejection", %{
    host: host
  } do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    {{:ok, issued}, rotated} =
      ExUnit.CaptureLog.with_log(
        [metadata: [:event, :host_id, :credential_id]],
        fn ->
          Credentials.rotate(host.id, 3600)
        end
      )

    assert rotated =~ "Host credentials rotated"
    assert rotated =~ "event=host.credentials_rotated"
    assert rotated =~ "host_id=" <> host.id
    assert rotated =~ "credential_id=" <> issued.id

    revoked =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :host_id]], fn ->
        assert {:ok, :ok} = Credentials.revoke(host.id)
      end)

    assert revoked =~ "Host credentials revoked"
    assert revoked =~ "event=host.credentials_revoked"

    rejected =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        assert {:error, :unauthorized} = Credentials.with_host("unwired-token", fn _ -> :ok end)
      end)

    assert rejected =~ "Host authentication rejected"
    assert rejected =~ "event=host.auth_rejected"
    assert rejected =~ "reason=unauthorized"
  end

  property "untrusted credential strings never authorize or invoke a callback" do
    check all(token <- binary(max_length: 200)) do
      assert {:error, :unauthorized} =
               Credentials.with_host(token, fn _ -> flunk("invalid credential accepted") end)
    end
  end

  # Keep key material out of assertion failure diagnostics.
  defp check_secret_absent!(value, secret) do
    if String.contains?(value, secret), do: flunk("credential unexpectedly exposed")
  end

  defp decrypts_to?(credential, secret) do
    loaded = Ash.load!(credential, :secret, actor: SystemActor.compute())
    Plug.Crypto.secure_compare(loaded.secret, secret)
  end
end
