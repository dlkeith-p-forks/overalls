defmodule Marshall.Compute.EnrollmentTest do
  use Marshall.DataCase, async: false
  alias Marshall.Compute.{Credentials, Enrollment, Host, Ledger, StoragePool}
  alias Marshall.Operations.PrivateFiles
  @moduletag :tmp_dir
  @fixtures Path.expand("../../fixtures/tls", __DIR__)

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)

    request = %{
      "version" => 3,
      "name" => "enrollment-#{Ash.UUID.generate()}",
      "architecture" => "x86_64",
      "machine_id" => "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      "overhead_cores" => 1,
      "overhead_memory_bytes" => 1_073_741_824,
      "credential_ttl_seconds" => 3600,
      "pools" => [
        %{
          "name" => "guests",
          "storage" => %{
            "backend" => "zfs",
            "zpool_guid" => "1",
            "dataset_guid" => "2",
            "dataset" => "tank/lilly"
          },
          "overhead_bytes" => 1_073_741_824
        }
      ]
    }

    path = Path.join(directory, "request.json")
    File.write!(path, JSON.encode!(request))
    File.chmod!(path, 0o600)
    %{request: request, request_path: path, output: Path.join(directory, "credential.json")}
  end

  test "operator enrollment retains a pinned endpoint through credential rotation", context do
    endpoint = Marshall.ComputeFixtures.transfer_endpoint()
    request = Map.put(context.request, "transfer_endpoint", endpoint)
    File.write!(context.request_path, JSON.encode!(request))
    assert {:ok, public} = Enrollment.enroll_file(context.request_path, context.output)
    assert public.transfer_endpoint == endpoint
    assert [host] = Ledger.read!(Host, id: public.host_id)
    assert host.transfer_endpoint == endpoint
    refute host.enabled
    assert host.reported_at == nil
    rotated = Path.join(context.tmp_dir, "rotated-transfer.json")
    assert {:ok, rotation} = Enrollment.rotate_file(host.id, 3600, rotated)
    assert rotation.transfer_endpoint == endpoint
    assert {:ok, verified} = Enrollment.verify_file(rotated)
    assert verified.transfer_endpoint == endpoint
  end

  test "resource validation and ordinary configuration cannot replace a transfer pin" do
    endpoint = Marshall.ComputeFixtures.transfer_endpoint()
    host = Marshall.ComputeFixtures.host_fixture(%{transfer_endpoint: endpoint}).host
    actor = Marshall.Authorization.SystemActor.compute()

    assert {:error, _} =
             host
             |> Ash.Changeset.for_update(
               :configure,
               %{transfer_endpoint: %{endpoint | "port" => 23}},
               actor: actor
             )
             |> Ash.update()

    assert [unchanged] = Ledger.read!(Host, id: host.id)
    assert unchanged.transfer_endpoint == endpoint

    assert {:error, _} =
             Host
             |> Ash.Changeset.for_create(
               :enroll,
               %{
                 name: "invalid-transfer-#{Ash.UUID.generate()}",
                 architecture: :x86_64,
                 transfer_endpoint: %{"address" => "host"}
               },
               actor: actor
             )
             |> Ash.create()
  end

  test "malformed transfer identity cannot create enrolled authority", context do
    request = Map.put(context.request, "transfer_endpoint", %{"address" => "host"})
    File.write!(context.request_path, JSON.encode!(request))

    assert {:error, :invalid_enrollment_request} =
             Enrollment.enroll_file(context.request_path, context.output)

    assert Ledger.read!(Host, name: context.request["name"]) == []
    refute File.exists?(context.output)
  end

  test "a pool carrying the retired logical budget cannot create enrolled authority", context do
    [pool] = context.request["pools"]
    budgeted = Map.put(pool, "logical_budget_bytes", pool["overhead_bytes"] + 1)
    File.write!(context.request_path, JSON.encode!(%{context.request | "pools" => [budgeted]}))

    assert {:error, :invalid_enrollment_request} =
             Enrollment.enroll_file(context.request_path, context.output)

    assert Ledger.read!(Host, name: context.request["name"]) == []
    refute File.exists?(context.output)
  end

  test "enrollment creates a disabled host and exports a private file accepted by the actual TLS client",
       context do
    assert {:ok, public} = Enrollment.enroll_file(context.request_path, context.output)
    assert public.enabled == false
    assert [%{name: "guests", filesystem_id: "zfs:1:2"}] = public.pools

    assert [%{enabled: false, effective_cores: 0, reported_at: nil}] =
             Ledger.read!(Host, id: public.host_id)

    assert [%{free_bytes: 0, reported_at: nil}] =
             Ledger.read!(StoragePool, host_id: public.host_id)

    assert {:ok, ^public} = Enrollment.verify_file(context.output)
    assert {:ok, ^public} = Enrollment.describe(context.request["name"])
    {:ok, token} = Lilly.Control.CredentialFile.read(context.output, public.host_id)
    absent? = not String.contains?(inspect(public), token)
    assert absent?

    client = tls_client(public, token)

    assert {:ok, _} = Lilly.Control.Client.open(client, Ash.UUID.generate())
    assert {:error, :host_not_ready} = Enrollment.set_enabled(public.host_id, true)
    assert {:ok, %{enabled: false}} = Enrollment.set_enabled(public.host_id, false)
  end

  test "v3 ZFS enrollment persists explicit identity without fabricating capacity", context do
    storage = %{
      "backend" => "zfs",
      "zpool_guid" => "18446744073709551615",
      "dataset_guid" => "456",
      "dataset" => "tank/lilly"
    }

    pool = %{"name" => "guests", "storage" => storage, "overhead_bytes" => 1_073_741_824}

    request = %{context.request | "version" => 3, "pools" => [pool]}
    File.write!(context.request_path, JSON.encode!(request))
    assert {:ok, public} = Enrollment.enroll_file(context.request_path, context.output)
    assert [descriptor] = public.pools
    assert descriptor.storage == storage
    refute Map.has_key?(descriptor, :logical_budget_bytes)
    assert descriptor.filesystem_id == "zfs:18446744073709551615:456"

    assert [%{backend: :zfs, reported_at: nil, free_bytes: 0, total_bytes: 0}] =
             Ledger.read!(StoragePool, host_id: public.host_id)

    assert {:ok, ^public} = Enrollment.verify_file(context.output)
    assert {:ok, token} = Lilly.Control.CredentialFile.read(context.output, public.host_id)

    assert {:ok, response} =
             Marshall.Compute.ProvisionerControl.open_execution(
               token,
               %{session_id: Ash.UUID.generate(), machine_id: public.machine_id}
             )

    assert [wire_pool] = response["pools"]
    assert wire_pool["storage"] == storage
    assert Map.keys(wire_pool) |> Enum.sort() == ~w(filesystem_id id name storage)
    refute Map.has_key?(response, "terminal_stream")

    # Exercise the actual consumer's descriptor parser and exchange encoder over TLS.
    # The observation is synthetic protocol evidence, not a native filesystem test.
    client = tls_client(public, token)
    assert {:ok, session} = Lilly.Control.Client.open(client, Ash.UUID.generate())
    assert session.pools == [wire_pool]
    {:ok, identity} = OverallsProtocol.Storage.identity(storage)
    gib = 1_073_741_824

    snapshot = %{
      id: descriptor.id,
      total_bytes: 10 * gib,
      free_bytes: 9 * gib,
      allocations: %{},
      storage:
        Map.merge(identity, %{
          used_bytes: gib,
          logical_used_bytes: 3 * gib,
          quota_bytes: 10 * gib,
          compression_ratio: 3.0
        })
    }

    report = %{
      sequence: 1,
      sampled_at: Ledger.now(),
      effective_cores: 5,
      effective_memory_bytes: 4 * gib,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => false,
        "terminal_protocol" => 0,
        "inception_image_id" => nil
      },
      pools: [snapshot]
    }

    assert {:ok, _} = Lilly.Control.Client.exchange_execution(client, session, report, [], [])

    assert [%{storage_observation: stored}] = Ledger.read!(StoragePool, id: descriptor.id)

    assert stored["zpool_guid"] == storage["zpool_guid"]
    assert stored["used_bytes"] == gib

    replaced = put_in(snapshot.storage.dataset_guid, "457")

    assert {:error, :invalid_report} =
             Lilly.Control.Client.exchange_execution(
               client,
               session,
               %{report | sequence: 2, pools: [replaced]},
               [],
               []
             )

    assert [%{report_sequence: 1}] = Ledger.read!(Host, id: public.host_id)
  end

  test "existing output, unsafe permissions and malformed requests cannot issue or replace authority",
       context do
    File.write!(context.output, "leave intact")
    File.chmod!(context.output, 0o600)
    assert {:error, :output_exists} = Enrollment.enroll_file(context.request_path, context.output)
    assert File.read!(context.output) == "leave intact"
    assert [] == Ledger.read!(Host, name: context.request["name"])
    File.rm!(context.output)
    File.chmod!(context.tmp_dir, 0o755)

    assert {:error, :unsafe_output_path} =
             Enrollment.enroll_file(context.request_path, context.output)

    File.chmod!(context.tmp_dir, 0o700)
    File.write!(context.request_path, JSON.encode!(Map.put(context.request, "enabled", true)))

    assert {:error, :invalid_enrollment_request} =
             Enrollment.enroll_file(context.request_path, context.output)

    refute File.exists?(context.output)
  end

  test "rotation and revocation make old files inactive without overwriting them", context do
    {:ok, public} = Enrollment.enroll_file(context.request_path, context.output)
    {:ok, token} = Lilly.Control.CredentialFile.read(context.output, public.host_id)
    rotated = Path.join(context.tmp_dir, "rotated.json")
    assert {:ok, next} = Enrollment.rotate_file(public.host_id, 3600, rotated)
    assert next.credential_id != public.credential_id
    assert {:error, :unauthorized} = Credentials.with_host(token, fn _ -> :ok end)
    assert {:error, :credential_inactive} = Enrollment.verify_file(context.output)
    assert {:ok, ^next} = Enrollment.verify_file(rotated)
    assert {:error, :output_exists} = Enrollment.rotate_file(public.host_id, 3600, rotated)
    assert {:ok, ^next} = Enrollment.verify_file(rotated)
    assert {:ok, %{revoked: true}} = Enrollment.revoke(public.host_id)
    assert {:error, :credential_inactive} = Enrollment.verify_file(rotated)
  end

  test "rollback after a synced file retains an inactive artifact and no partial host", context do
    assert {:error, :injected_after_file} =
             Repo.transaction(fn ->
               assert {:ok, _} = Enrollment.enroll_file(context.request_path, context.output)
               Repo.rollback(:injected_after_file)
             end)

    assert {:ok, _} = PrivateFiles.read(context.output)
    assert [] == Ledger.read!(Host, name: context.request["name"])
    assert {:error, :credential_inactive} = Enrollment.verify_file(context.output)
    assert {:error, :output_exists} = Enrollment.enroll_file(context.request_path, context.output)
  end

  test "a duplicate physical host rolls back the new enrollment and leaves a verifiable failure",
       context do
    {:ok, original} = Enrollment.enroll_file(context.request_path, context.output)
    other = Path.join(context.tmp_dir, "other.json")

    File.write!(
      context.request_path,
      JSON.encode!(Map.put(context.request, "name", "other-host"))
    )

    assert {:error, _} = Enrollment.enroll_file(context.request_path, other)
    assert [] == Ledger.read!(Host, name: "other-host")
    assert {:ok, ^original} = Enrollment.verify_file(context.output)
    assert {:error, :invalid_credential_file} = Enrollment.verify_file(other)
  end

  test "unreadable encrypted authority is unavailable, not proof that a file is inactive",
       context do
    {:ok, public} = Enrollment.enroll_file(context.request_path, context.output)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_host_credentials SET encrypted_secret = $1 WHERE id = $2",
      [<<0, 1, 2>>, Ecto.UUID.dump!(public.credential_id)]
    )

    assert {:error, :verification_unavailable} = Enrollment.verify_file(context.output)
    assert {:ok, ^public} = Enrollment.describe(context.request["name"])
  end

  test "operator enable, disable, rotation and revocation preserve existing allocations",
       context do
    fixture = Marshall.ComputeFixtures.host_fixture()
    actor = Marshall.ComputeFixtures.user()
    {:ok, vm} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: actor)
    original = Ledger.read!(Marshall.Compute.Reservation, vm_id: vm.id)
    assert original != []
    assert {:ok, %{enabled: false}} = Enrollment.set_enabled(fixture.host.id, false)

    assert {:error, _} =
             Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: actor)

    assert {:ok, %{enabled: true}} = Enrollment.set_enabled(fixture.host.id, true)
    assert {:ok, _} = Enrollment.rotate_file(fixture.host.id, 3600, context.output)
    assert {:error, :host_not_ready} = Enrollment.set_enabled(fixture.host.id, true)
    assert {:ok, %{revoked: true}} = Enrollment.revoke(fixture.host.id)
    assert Ledger.read!(Marshall.Compute.Reservation, vm_id: vm.id) == original
  end

  test "operator enrollment diagnostics stay catalogued inside the privacy boundary", context do
    fixture = Marshall.ComputeFixtures.host_fixture()

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    disabled =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :host_id, :operation_status]], fn ->
        assert {:ok, %{enabled: false}} = Enrollment.set_enabled(fixture.host.id, false)
      end)

    assert disabled =~ "Operator process diagnostic (payload redacted)"
    assert disabled =~ "event=host.admission_changed"
    assert disabled =~ "host_id=" <> fixture.host.id
    assert disabled =~ "operation_status=disabled"

    issued =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :host_id]], fn ->
        assert {:ok, _} = Enrollment.rotate_file(fixture.host.id, 3600, context.output)
      end)

    assert issued =~ "event=host.credential_file_issued"
    assert issued =~ "host_id=" <> fixture.host.id

    revoked =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :host_id]], fn ->
        assert {:ok, %{revoked: true}} = Enrollment.revoke(fixture.host.id)
      end)

    assert revoked =~ "event=host.credentials_revoked"
    assert revoked =~ "host_id=" <> fixture.host.id
  end

  defp tls_client(public, token) do
    server =
      start_supervised!(
        {Bandit,
         plug: Marshall.AudiControl.FleetPlug,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Lilly.Control.Client.new("https://localhost:#{port}", public.host_id, token,
        protocol_version: 4,
        machine_id: public.machine_id,
        cacertfile: Path.join(@fixtures, "ca.pem")
      )

    Marshall.LillyControl.connect(client)
  end

  test "five-year preparation retries recover one disabled registration", c do
    alias Marshall.Compute.{CredentialLifetime, EnrollmentPreparation, HostCredential}
    request = Map.put(c.request, "credential_ttl_seconds", CredentialLifetime.maximum())
    File.write!(c.request_path, JSON.encode!(request))
    operation = Ash.UUID.generate()
    before = Ledger.now()

    assert {:ok, public} =
             EnrollmentPreparation.prepare_file(operation, :prepare, c.request_path, c.output)

    assert {:ok, expiry, 0} = DateTime.from_iso8601(public.expires_at)

    assert DateTime.diff(expiry, before) in CredentialLifetime.maximum()..(CredentialLifetime.maximum() +
                                                                             1)

    first = File.read!(c.output)
    retry = Path.join(c.tmp_dir, "retry.json")

    assert {:ok, ^public} =
             EnrollmentPreparation.prepare_file(operation, :prepare, c.request_path, retry)

    assert File.read!(retry) == first
    assert [host] = Ledger.read!(Host, id: public.host_id)
    refute host.enabled
    assert host.reported_at == nil
    assert [_] = Ledger.read!(HostCredential, host_id: host.id)
    assert {:ok, _} = Enrollment.verify_file(retry)
    # A new preparation operation also reuses matching current authority.
    another = Path.join(c.tmp_dir, "another.json")

    assert {:ok, same} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               c.request_path,
               another
             )

    assert same.credential_id == public.credential_id
    assert File.read!(another) == first
  end

  test "rotation retries do not issue twice and older preparation cannot resurrect authority",
       c do
    alias Marshall.Compute.EnrollmentPreparation
    initial = Ash.UUID.generate()

    assert {:ok, first} =
             EnrollmentPreparation.prepare_file(initial, :prepare, c.request_path, c.output)

    operation = Ash.UUID.generate()
    rotated = Path.join(c.tmp_dir, "rotated.json")

    assert {:ok, next} =
             EnrollmentPreparation.prepare_file(operation, :rotate, c.request_path, rotated)

    refute next.credential_id == first.credential_id
    assert {:error, :credential_inactive} = Enrollment.verify_file(c.output)
    retry = Path.join(c.tmp_dir, "retry.json")

    assert {:ok, ^next} =
             EnrollmentPreparation.prepare_file(operation, :rotate, c.request_path, retry)

    assert File.read!(retry) == File.read!(rotated)

    assert {:error, :credential_inactive} =
             EnrollmentPreparation.prepare_file(
               initial,
               :prepare,
               c.request_path,
               Path.join(c.tmp_dir, "old.json")
             )

    assert {:ok, _} = Enrollment.verify_file(rotated)
  end

  test "preparation conflicts and revoked authority fail without replacement", c do
    alias Marshall.Compute.EnrollmentPreparation
    operation = Ash.UUID.generate()

    assert {:ok, first} =
             EnrollmentPreparation.prepare_file(operation, :prepare, c.request_path, c.output)

    File.write!(c.request_path, JSON.encode!(Map.put(c.request, "overhead_cores", 2)))

    assert {:error, :registration_conflict} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               c.request_path,
               Path.join(c.tmp_dir, "conflict.json")
             )

    File.write!(c.request_path, JSON.encode!(Map.put(c.request, "credential_ttl_seconds", 100)))

    assert {:error, :operation_conflict} =
             EnrollmentPreparation.prepare_file(
               operation,
               :prepare,
               c.request_path,
               Path.join(c.tmp_dir, "changed.json")
             )

    File.write!(c.request_path, JSON.encode!(c.request))
    assert {:ok, :ok} = Credentials.revoke(first.host_id)

    assert {:error, :credential_inactive} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               c.request_path,
               Path.join(c.tmp_dir, "revoked.json")
             )
  end

  test "lifetime boundary is enforced by parser, rotation and issuance", c do
    alias Marshall.Compute.{CredentialLifetime, EnrollmentRequest}
    assert {:ok, public} = Enrollment.enroll_file(c.request_path, c.output)

    for ttl <- [0, -1, CredentialLifetime.maximum() + 1, 1.0, "157680000", nil] do
      assert {:error, :invalid_enrollment_request} =
               EnrollmentRequest.parse(Map.put(c.request, "credential_ttl_seconds", ttl))

      assert {:error, :invalid_lifetime} = Credentials.rotate(public.host_id, ttl)

      assert {:error, :invalid_rotation_request} =
               Enrollment.rotate_file(public.host_id, ttl, Path.join(c.tmp_dir, "invalid.json"))
    end

    assert {:ok, unchanged} = Enrollment.verify_file(c.output)
    assert unchanged.expires_at == public.expires_at

    assert {:ok, _} =
             Enrollment.rotate_file(
               public.host_id,
               CredentialLifetime.maximum(),
               Path.join(c.tmp_dir, "five-years.json")
             )
  end

  test "storage conflict and retirement cannot replace enrolled authority", c do
    alias Marshall.Compute.EnrollmentPreparation
    operation = Ash.UUID.generate()

    assert {:ok, public} =
             EnrollmentPreparation.prepare_file(operation, :prepare, c.request_path, c.output)

    changed = put_in(c.request, ["pools", Access.at(0), "storage", "dataset_guid"], "3")
    File.write!(c.request_path, JSON.encode!(changed))

    assert {:error, :registration_conflict} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               c.request_path,
               Path.join(c.tmp_dir, "storage-conflict.json")
             )

    File.write!(c.request_path, JSON.encode!(c.request))
    [host] = Ledger.read!(Host, id: public.host_id)
    Ledger.update!(host, :maintenance, %{maintenance_mode: :retired, enabled: false})

    for kind <- [:prepare, :rotate] do
      assert {:error, :host_retired} =
               EnrollmentPreparation.prepare_file(
                 operation,
                 kind,
                 c.request_path,
                 Path.join(c.tmp_dir, "retired-#{kind}.json")
               )
    end

    assert [credential] = Ledger.read!(Marshall.Compute.HostCredential, host_id: host.id)
    assert credential.id == public.credential_id
  end

  test "manual enrollment shares the per-name lock fence and the retired fence", c do
    alias Marshall.Compute.{Drains, EnrollmentPreparation, ProvisionerControl}
    assert {:ok, public} = Enrollment.enroll_file(c.request_path, c.output)
    name = c.request["name"]

    # Re-enrolling the same name is a precise conflict before any issuance.
    duplicate = Path.join(c.tmp_dir, "duplicate.json")

    assert {:error, :registration_conflict} =
             Enrollment.enroll_file(c.request_path, duplicate)

    assert File.read!(duplicate) == ""
    assert File.lstat!(duplicate).mode |> Bitwise.band(0o777) == 0o600
    assert [%{id: host_id}] = Ledger.read!(Host, name: name)
    assert host_id == public.host_id

    # A prepared retry of the enrolled name reuses existing authority.
    prepared = Path.join(c.tmp_dir, "prepared-again.json")

    assert {:ok, same} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               c.request_path,
               prepared
             )

    assert same.credential_id == public.credential_id
    assert File.read!(prepared) == File.read!(c.output)

    # Drive the real report/drain/retire chain, which revokes authority.
    [host] = Ledger.read!(Host, id: public.host_id)
    {:ok, credential} = Credentials.rotate(host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(credential.token, %{
        session_id: Ash.UUID.generate(),
        machine_id: host.machine_id
      })

    pool = hd(Ledger.read!(StoragePool, host_id: host.id))

    report = %{
      sequence: 1,
      sampled_at: Ledger.now(),
      effective_cores: 2,
      effective_memory_bytes: 2_147_483_648,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => true,
        "terminal_protocol" => 2,
        "inception_image_id" => nil
      },
      pools: [
        %{
          id: pool.id,
          total_bytes: 10_737_418_240,
          free_bytes: 10_737_418_240,
          allocations: %{},
          storage: %{
            backend: :zfs,
            zpool_guid: pool.zpool_guid,
            dataset_guid: pool.dataset_guid,
            dataset: pool.dataset,
            used_bytes: 0,
            logical_used_bytes: 0,
            quota_bytes: 10_737_418_240,
            compression_ratio: 1.0
          }
        }
      ]
    }

    assert {:ok, _} =
             ProvisionerControl.exchange_execution(credential.token, %{
               session_id: session["session_id"],
               epoch: session["epoch"],
               report: report,
               acknowledgements: [],
               outcomes: []
             })

    assert {:ok, _} = Enrollment.set_enabled(host.id, true)
    id = Ash.UUID.generate()
    assert {:ok, %{status: "draining"}} = Drains.request(host.id, id, "test:112")
    assert {:ok, 0} = Drains.advance(id)
    assert {:ok, %{status: "drained"}} = Drains.status(id)
    assert {:ok, %{status: "retired", host_mode: "retired"}} = Drains.retire(id)

    # The retired fence refuses name recycling forever, before any issuance.
    recycled =
      put_in(
        c.request,
        ["machine_id"],
        "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      )

    recycled_path = Path.join(c.tmp_dir, "recycled.json")
    File.write!(recycled_path, JSON.encode!(recycled))
    File.chmod!(recycled_path, 0o600)
    out = Path.join(c.tmp_dir, "recycled-out.json")

    assert {:error, :host_retired} = Enrollment.enroll_file(recycled_path, out)
    assert File.read!(out) == ""
    assert File.lstat!(out).mode |> Bitwise.band(0o777) == 0o600
    assert [] == Ledger.read!(Host, machine_id: recycled["machine_id"])

    assert {:error, :host_retired} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               recycled_path,
               Path.join(c.tmp_dir, "recycled-prepare.json")
             )

    # Rotation through the operator file refuses retired authority without issuing.
    rotated = Path.join(c.tmp_dir, "rotated.json")

    assert {:error, :host_retired} = Enrollment.rotate_file(host.id, 3600, rotated)
    assert File.read!(rotated) == ""
    assert File.lstat!(rotated).mode |> Bitwise.band(0o777) == 0o600
    assert [] == Ledger.read!(Marshall.Compute.HostCredential, host_id: host.id)

    # Refused artifacts remain inspection-only and are never overwritten.
    assert {:error, :output_exists} = Enrollment.rotate_file(host.id, 3600, rotated)

    # The original enrolled file verifies as permanently inactive.
    assert {:error, :credential_inactive} = Enrollment.verify_file(c.output)
  end

  test "conflicting same-name registration refuses precisely in both entry orders", c do
    alias Marshall.Compute.EnrollmentPreparation
    name = c.request["name"]

    conflicting =
      put_in(
        c.request,
        ["machine_id"],
        "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      )

    conflicting_path = Path.join(c.tmp_dir, "conflicting.json")
    File.write!(conflicting_path, JSON.encode!(conflicting))
    File.chmod!(conflicting_path, 0o600)

    # Manual first, prepared second: the conflicting machine refuses.
    assert {:ok, manual} = Enrollment.enroll_file(c.request_path, c.output)

    assert {:error, :registration_conflict} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               conflicting_path,
               Path.join(c.tmp_dir, "prepared-conflict.json")
             )

    assert [%{id: enrolled_id}] = Ledger.read!(Host, name: name)
    assert enrolled_id == manual.host_id

    # Prepared first, manual second order is covered by the same assertion on a
    # fresh name: enroll after prepare refuses the conflicting machine.
    name2 = "order-" <> Ash.UUID.generate()
    other = %{conflicting | "name" => name2}
    other_path = Path.join(c.tmp_dir, "other.json")
    File.write!(other_path, JSON.encode!(other))
    File.chmod!(other_path, 0o600)

    assert {:ok, _} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               other_path,
               Path.join(c.tmp_dir, "other-out.json")
             )

    earlier_machine = c.request["machine_id"]
    manual_again = %{c.request | "name" => name2, "machine_id" => earlier_machine}
    manual_path = Path.join(c.tmp_dir, "manual-again.json")
    File.write!(manual_path, JSON.encode!(manual_again))
    File.chmod!(manual_path, 0o600)

    assert {:error, :registration_conflict} =
             Enrollment.enroll_file(manual_path, Path.join(c.tmp_dir, "manual-again-out.json"))

    assert [%{machine_id: machine}] = Ledger.read!(Host, name: name2)
    assert machine == other["machine_id"]
  end

  test "preparation failure taxonomy is preserved across its file boundary", c do
    alias Marshall.Compute.EnrollmentPreparation
    operation = Ash.UUID.generate()

    # Existing destination refuses before any authority change.
    occupied = Path.join(c.tmp_dir, "occupied.json")
    File.write!(occupied, "occupied")
    File.chmod!(occupied, 0o600)

    assert {:error, :output_exists} =
             EnrollmentPreparation.prepare_file(operation, :prepare, c.request_path, occupied)

    assert [] == Ledger.read!(Marshall.Compute.EnrollmentOperation, id: operation)

    # Unreadable or malformed requests report the fixed invalid-request class.
    assert {:error, :invalid_enrollment_request} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               c.tmp_dir,
               Path.join(c.tmp_dir, "unreadable.json")
             )

    malformed = Path.join(c.tmp_dir, "malformed.json")
    File.write!(malformed, "not json")
    File.chmod!(malformed, 0o600)

    assert {:error, :invalid_enrollment_request} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               malformed,
               Path.join(c.tmp_dir, "malformed-out.json")
             )

    refute File.exists?(Path.join(c.tmp_dir, "unreadable.json"))
    refute File.exists?(Path.join(c.tmp_dir, "malformed-out.json"))

    # Unsafe output permissions report their own class without touching input.
    File.chmod!(c.tmp_dir, 0o755)

    assert {:error, :unsafe_output_path} =
             EnrollmentPreparation.prepare_file(
               Ash.UUID.generate(),
               :prepare,
               c.request_path,
               Path.join(c.tmp_dir, "unsafe-out.json")
             )

    File.chmod!(c.tmp_dir, 0o700)
  end
end
