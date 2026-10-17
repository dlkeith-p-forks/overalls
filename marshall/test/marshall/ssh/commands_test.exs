defmodule Marshall.SSH.CommandsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.{Compute, SSH}

  alias Marshall.Compute.{
    Host,
    Ledger,
    Operation,
    Outcomes,
    Relocation,
    Reservation,
    VirtualMachine
  }

  alias Marshall.Authorization.SystemActor
  alias Marshall.Access.Grant
  alias Marshall.SSH.{Request, Token}

  setup do
    fixture = host_fixture()
    actor = user()
    public_key = public_key(<<1::256>>)
    {:ok, key} = SSH.add_key(%{public_key: public_key}, actor: actor)
    {gateway_token, _} = Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "command-fixture", token: gateway_token},
        actor: SystemActor.compute()
      )

    {:ok, session} =
      SSH.open_session(%{gateway_token: gateway_token, public_key: public_key},
        actor: SystemActor.compute()
      )

    previous = Application.fetch_env(:marshall, :default_image_id)
    Application.put_env(:marshall, :default_image_id, image_id())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:marshall, :default_image_id, value)
        :error -> Application.delete_env(:marshall, :default_image_id)
      end
    end)

    Map.merge(fixture, %{
      actor: actor,
      key: key,
      public_key: public_key,
      gateway_token: gateway_token,
      session_token: session.session_token
    })
  end

  test "clone commands queue distinct copies and retries retain the original request", c do
    assert {:ok, created} = command(c, "new --name clone-source --request-id source")
    assert created.status == "accepted"
    assert {:ok, first} = command(c, "clone clone-source --request-id copy-one --no-wait")
    assert first.status == "accepted"
    assert {:ok, replay} = command(c, "clone clone-source --request-id copy-one --no-wait")
    assert replay.operation_id == first.operation_id
    assert replay.result["destination_vm_id"] == first.result["destination_vm_id"]
    assert {:ok, second} = command(c, "clone clone-source --request-id copy-two --no-wait")
    refute second.operation_id == first.operation_id

    assert {:ok, cancelled} =
             command(c, "request cancel copy-one --request-id cancel-one --no-wait")

    assert cancelled.operation_id == first.operation_id
    assert {:ok, status} = command(c, "request show copy-one")
    assert status.status == "superseded"
    assert {:ok, cancel_status} = command(c, "request show cancel-one")
    assert cancel_status.status == "succeeded"
    assert cancel_status.result["phase"] == "cancelled"
    assert length(Ledger.read!(Marshall.Compute.CloneRequest)) == 2
  end

  # @cc [owner:ghuntley,label:verification;product] ssh-resize-command-tested
  # Porsche resize MUST accept a size change on a stable machine, replay the
  # same request id to the same receipt, refuse a request without any size,
  # and let the same receipt be cancelled before any size applies.
  test "resize commands accept, replay, refuse empty changes and cancel before mutation", c do
    assert {:ok, created} = command(c, "new --name resize-target --request-id rt-create")
    [provision] = Ledger.read!(Operation, id: created.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(provision, 1, :running))

    assert {:error, %{errors: [%{reason: :invalid_vm_size}]}} =
             command(c, "resize resize-target --request-id rt-empty --no-wait")

    assert {:ok, accepted} =
             command(c, "resize resize-target --cpu 2 --request-id rt-1 --no-wait")

    assert accepted.status == "accepted"
    assert accepted.result["target_sizes"]["vcpu"] == 2
    assert accepted.result["phase"] == "stopping"
    assert {:ok, replay} = command(c, "resize resize-target --cpu 2 --request-id rt-1 --no-wait")
    assert replay.operation_id == accepted.operation_id
    assert {:ok, shown} = command(c, "request show rt-1")
    assert shown.status == "accepted"

    # A second resize while one is active is refused by the busy guard; the
    # gateway transaction owns and logs that refusal (api.request_unauthorized).
    assert {:error, %{errors: [%{reason: :vm_busy}]}} =
             command(c, "resize resize-target --cpu 3 --request-id rt-2 --no-wait")

    assert {:ok, cancel} = command(c, "request cancel rt-1 --request-id rt-cancel --no-wait")
    assert cancel.status == "accepted"
    assert cancel.result["phase"] == "cancelling"
    assert {:ok, %{status: "accepted"}} = command(c, "request show rt-1")
  end

  test "list and show expose the current host name without internal placement IDs", c do
    assert {:ok, created} = command(c, "new --name placed-machine --request-id placed-create")
    assert {:ok, listed} = command(c, "ls")
    assert [%{"host" => host, "id" => id}] = listed.result["items"]
    assert host == c.host.name
    assert id == created.result["id"]

    ssh_host =
      OverallsProtocol.IngressName.label("placed-machine", id) <> ".apps.example.test"

    assert hd(listed.result["items"])["ssh_host"] == ssh_host
    refute Map.has_key?(hd(listed.result["items"]), "host_id")
    refute Map.has_key?(hd(listed.result["items"]), "current_placement_id")
    refute Map.has_key?(hd(listed.result["items"]), "editor_image_status")

    assert {:ok, shown} = command(c, "show placed-machine")
    assert shown.result["host"] == c.host.name
    assert shown.result["ssh_host"] == ssh_host
    refute Map.has_key?(shown.result, "host_id")
    refute Map.has_key?(shown.result, "current_placement_id")
    refute Map.has_key?(shown.result, "execution_epoch")
    refute Map.has_key?(shown.result, "editor_image_status")

    fields =
      ~w(architecture desired_state disk_bytes execution_ref failure_reason generation host id image_id inserted_at memory_bytes name observed_state owner permissions profile relocation resize ssh_host vcpu)

    assert Map.keys(shown.result) |> Enum.sort() == fields
    assert Map.keys(hd(listed.result["items"])) |> Enum.sort() == fields
    assert shown.result["execution_ref"] == hd(listed.result["items"])["execution_ref"]

    for field <- [:generation, :execution_epoch] do
      assert {:ok, before} = Marshall.Compute.get_vm(%{vm_id: id}, actor: c.actor)
      [vm] = Ledger.read!(VirtualMachine, id: id)
      Ash.Seed.update!(vm, %{field => Map.fetch!(vm, field) + 1})
      assert {:ok, after_change} = Marshall.Compute.get_vm(%{vm_id: id}, actor: c.actor)
      refute before.execution_ref == after_change.execution_ref
    end
  end

  test "new defaults to OSS and preserves an explicit Customer profile", c do
    assert {:ok, default} = command(c, "new --name oss-default --request-id oss-default")
    assert default.result["profile"] == "oss"
    assert [%{profile: :oss}] = Ledger.read!(VirtualMachine, id: default.result["id"])

    assert {:ok, customer} =
             command(
               c,
               "new --name customer-explicit --profile customer --request-id customer-explicit"
             )

    assert customer.result["profile"] == "customer"
    assert [%{profile: :customer}] = Ledger.read!(VirtualMachine, id: customer.result["id"])
  end

  test "new --source records the repository and replays by request id", c do
    url = "https://github.com/tastejs/todomvc/tree/main"

    assert {:ok, created} =
             command(c, "new --name launched --source #{url} --request-id source-1 --json")

    assert created.result["workspace_source"] == url
    assert created.result["name"] == "launched"
    assert created.result["profile"] == "oss"

    assert Map.keys(created.result) |> Enum.sort() ==
             ~w(disk_bytes id image_id memory_bytes name profile ssh_host vcpu workspace_source)

    assert {:ok, %{result: shown}} = command(c, "show launched --json")
    assert is_binary(shown["ssh_host"])
    assert created.result["ssh_host"] == shown["ssh_host"]

    id = created.result["id"]

    assert [
             %{
               provider: :github,
               namespace: ["tastejs"],
               repository: "todomvc",
               revision: %{"kind" => "ref", "value" => "main"}
             }
           ] =
             Ledger.read!(Marshall.Compute.WorkspaceSource, vm_id: id)

    [operation] = Ledger.read!(Operation, id: created.operation_id)

    assert {:ok, %{workspace_source: %{revision: %{kind: :ref, value: "main"}}}} =
             OverallsProtocol.Execution.command(operation.command_snapshot)

    # An equivalent spelling of the same source replays the pinned receipt.
    assert {:ok, ^created} =
             command(c, "new --name launched --source #{url}/ --request-id source-1")

    for other <- ["https://github.com/tastejs/todomvc", "https://github.com/tastejs/other"] do
      assert {:error, error} =
               command(c, "new --name launched --source #{other} --request-id source-1")

      assert Exception.message(error) =~ "idempotency_conflict"
    end

    assert {:error, error} = command(c, "new --name launched --request-id source-1")
    assert Exception.message(error) =~ "idempotency_conflict"
    assert [_] = Ledger.read!(VirtualMachine)
    assert [_] = Ledger.read!(Operation)
    assert [_] = Ledger.read!(Request)
  end

  test "overalls open's new command line waits for a running outcome", c do
    visit = String.duplicate("0123456789abcdef", 2)
    url = "https://github.com/tastejs/todomvc"

    line =
      "new --source #{url} --profile oss --request-id overalls-open-#{visit} --timeout 600 --json"

    assert {:ok, accepted} = command(c, line)
    assert accepted.status == "accepted"
    assert accepted.request_id == "overalls-open-" <> visit
    [operation] = Ledger.read!(Operation, id: accepted.operation_id)
    Ledger.update!(operation, :acknowledge, %{})
    assert {:ok, _} = ingest(c.host.id, outcome(operation, 2, :running))

    assert {:ok, %{status: "succeeded", result: result}} = command(c, line)
    assert result["outcome"] == "running"
    assert result["id"] == accepted.result["id"]
    assert result["name"] == accepted.result["name"]
    assert result["workspace_source"] == url
    assert is_binary(result["ssh_host"])
  end

  test "new --source refuses an explicit Customer profile before allocation", c do
    assert {:error, error} =
             command(
               c,
               "new --profile customer --source https://github.com/tastejs/todomvc --request-id source-customer"
             )

    assert Exception.message(error) =~ "workspace_source_not_allowed"
    assert Ledger.read!(VirtualMachine) == []
    assert Ledger.read!(Reservation) == []
    assert Ledger.read!(Operation) == []
    assert Ledger.read!(Request) == []
    assert Ledger.read!(Marshall.Compute.WorkspaceSource) == []
  end

  test "new without --source keeps its result shape and records no source", c do
    assert {:ok, created} = command(c, "new --request-id no-source --json")
    refute Map.has_key?(created.result, "workspace_source")
    assert Ledger.read!(Marshall.Compute.WorkspaceSource) == []
  end

  test "new keeps guest keys out of provision authority and replay identity", c do
    assert {:ok, created} = command(c, "new --name ssh-guest --request-id ssh-guest-create")
    assert [_vm] = Ledger.read!(VirtualMachine, id: created.result["id"])
    assert [operation] = Ledger.read!(Operation, id: created.operation_id)
    refute Map.has_key?(operation.command_snapshot, "ssh_public_key")

    assert {:ok, shown} = command(c, "show ssh-guest")
    refute Map.has_key?(shown.result, "ssh_public_key")

    another_key = session_for(c, c.actor, <<3::256>>)

    assert {:ok, replay} =
             command(another_key, "new --name ssh-guest --request-id ssh-guest-create --no-wait")

    assert replay.result["id"] == created.result["id"]
    assert length(Ledger.read!(VirtualMachine, name: "ssh-guest")) == 1
  end

  # @cc [owner:ghuntley,label:verification;security] lifecycle-entry-authority-oracle
  # Generated start/stop/rm histories across profiles and actors MUST admit only
  # current managing authority. A refusal MUST leave the complete durable intent
  # inventory byte-identical, enqueue nothing and persist no receipt; an
  # acceptance MUST add exactly one operation, one request and one dispatch.
  # Receipts MUST replay only for their accepted actor; a changed kind with a
  # used request key MUST conflict without new durable work.
  property "lifecycle commands across profiles admit only current authority", c do
    check all(
            profile <- member_of(["oss", "customer"]),
            performers <-
              if(
                profile == "oss",
                do: list_of(member_of([:owner, :member]), length: 3),
                else: constant([:owner, :owner, :owner])
              ),
            refusals <-
              list_of(
                tuple(
                  {member_of(
                     if(profile == "oss",
                       do: [:revoked, :stranger, :admin],
                       else: [:member, :revoked, :stranger, :admin]
                     )
                   ), member_of([:stop, :start, :rm, :show])}
                ),
                min_length: 6,
                max_length: 12
              ),
            max_runs: 8
          ) do
      actors = history_actors(c)
      refresh_reports(c)
      name = "ctl-" <> binary_part(Ash.UUID.generate(), 0, 8)
      create_key = Ash.UUID.generate()

      created_result =
        command(c, "new --name #{name} --profile #{profile} --request-id #{create_key}")

      assert {:ok, created} = created_result

      assert created.result["profile"] == profile
      vm_id = created.result["id"]
      [provision] = Ledger.read!(Operation, id: created.operation_id)
      assert {:ok, _} = ingest(c.host.id, outcome(provision, 1, :running))
      assert {:ok, %{status: "succeeded"}} = command(c, "request show #{create_key}")
      wire_membership(c, actors, profile, name, vm_id)

      refusers =
        if profile == "oss",
          do: [:revoked, :stranger, :admin],
          else: [:member, :revoked, :stranger, :admin]

      for refused <- refusers do
        assert {:ok, listed} = command(actors[refused], "ls")
        assert listed.result["items"] == []
      end

      [p0, p1, p2] = performers
      steps = [{:stop, p0}, {:start, p1}, {:rm, p2}]

      chunks =
        refusals
        |> Enum.with_index()
        |> Enum.group_by(fn {_, index} -> rem(index, 4) end, fn {refusal, _} -> refusal end)

      {_, settled} =
        steps
        |> Enum.with_index()
        |> Enum.reduce({2, %{}}, fn {{kind, performer}, chunk}, {sequence, settled} ->
          for {refused, attempt} <- Map.get(chunks, chunk, []) do
            refused_entry(actors, refused, attempt, name)
          end

          settle = accepted_lifecycle(c, actors[performer], kind, name, vm_id, sequence)

          other = if performer == :owner, do: :member, else: :owner
          assert {:error, _} = command(actors[other], "request show #{settle.key}")
          assert {:error, _} = command(actors.stranger, "request show #{settle.key}")
          assert {:error, _} = command(actors.admin, "request show #{settle.key}")

          {sequence + 1, Map.put(settled, kind, settle)}
        end)

      for {refused, attempt} <- Map.get(chunks, 3, []) do
        refused_entry(actors, refused, attempt, name)
      end

      close_history(c, actors, name, vm_id, settled)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] customer-archived-receipt-pinning
  # Deleting an archived Customer VM's name MUST keep old lifecycle receipts
  # readable only to their owner, pinned to the deleted machine; name reuse
  # creates a distinct machine that the retained receipt cannot retarget.
  test "customer receipts stay owner-pinned through deletion and name reuse", c do
    member = user()
    peer = session_for(c, member, <<3::256>>)
    name = "archived-customer-" <> binary_part(Ash.UUID.generate(), 0, 16)

    {:ok, created} =
      command(c, "new --name #{name} --profile customer --request-id new-customer-1")

    Ledger.create!(Grant, :grant, %{
      vm_id: created.result["id"],
      user_id: member.id,
      granted_by_id: c.actor.id,
      role: :manager
    })

    [provision] = Ledger.read!(Operation, id: created.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(provision, 1, :running))

    {:ok, %{status: "succeeded", result: %{"id" => id}}} =
      command(c, "request show new-customer-1")

    assert id == created.result["id"]
    {:ok, deleted} = command(c, "rm #{name} --request-id remove-customer-1")
    [operation] = Ledger.read!(Operation, id: deleted.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(operation, 2, :deleted))
    {:ok, finished} = command(c, "request show remove-customer-1")
    assert finished.status == "succeeded"
    assert finished.result["id"] == created.result["id"]
    assert {:ok, %{status: "succeeded"}} = command(c, "request show new-customer-1")

    assert [%{archived_at: %DateTime{}}] =
             Ledger.history!(VirtualMachine, id: created.result["id"])

    before = oracle_inventory()
    assert {:error, _} = command(peer, "request show remove-customer-1")
    assert {:error, _} = command(peer, "rm #{name} --request-id member-remove-1")
    assert {:error, _} = command(peer, "show #{name}")
    assert {:error, _} = command(peer, "stop #{name} --request-id member-stop-1")
    assert [] = Ledger.read!(Request, user_id: member.id)
    assert oracle_inventory() == before
    assert command(c, "ls") |> elem(1) |> Map.fetch!(:result) |> Map.fetch!("items") == []

    {:ok, successor} =
      command(c, "new --name #{name} --profile customer --request-id new-customer-2")

    refute successor.result["id"] == created.result["id"]
    assert {:ok, ^finished} = command(c, "request show remove-customer-1")

    assert [%{desired_state: :running}] =
             Ledger.read!(VirtualMachine, id: successor.result["id"])

    [cleanup] = Ledger.read!(Operation, id: successor.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(cleanup, 1, :running))
    {:ok, successor_delete} = command(c, "rm #{name} --request-id remove-customer-2")
    assert successor_delete.operation_id != deleted.operation_id
    [removal] = Ledger.read!(Operation, id: successor_delete.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(removal, 2, :deleted))
  end

  # @cc [owner:ghuntley,label:verification;recovery] profile-retry-identity-oracle
  # Generated retries MUST preserve the admitted profile and one VM/operation.
  # An omitted profile and any explicit profile are different semantic inputs,
  # even explicit OSS; changing that input MUST refuse without new durable work.
  property "omitted and explicit profiles stay pinned through retry histories", c do
    check all(
            selection <- member_of([nil, "oss", "customer", "standard"]),
            attempts <-
              list_of(member_of([:retry, :explicit_oss, :customer, :omit]),
                min_length: 1,
                max_length: 8
              ),
            max_runs: 16
          ) do
      Ledger.update!(c.host, :report, %{reported_at: Ledger.now()})
      key = Ash.UUID.generate()
      profile_option = if selection, do: " --profile #{selection}", else: ""
      original = "new --cpu 1 --request-id #{key}" <> profile_option
      assert {:ok, receipt} = command(c, original)
      expected = selection || "oss"
      assert receipt.result["profile"] == expected
      vm_id = receipt.result["id"]
      [vm] = Ledger.read!(VirtualMachine, id: vm_id)
      assert Atom.to_string(vm.profile) == expected
      admitted_rows = durable_profile_rows()

      # Every generated history includes both replay and a decisive conflict.
      for attempt <- [:retry, if(selection == "customer", do: :omit, else: :customer)] ++ attempts do
        selected =
          case attempt do
            :retry -> selection
            :explicit_oss -> "oss"
            :customer -> "customer"
            :omit -> nil
          end

        option = if selected, do: " --profile #{selected}", else: ""
        result = command(c, "new --cpu 1 --request-id #{key} --json --no-wait" <> option)

        if selected == selection do
          assert result == {:ok, receipt}
        else
          assert {:error, error} = result
          assert Exception.message(error) =~ "idempotency_conflict"
        end

        assert [%{id: ^vm_id, profile: profile}] = Ledger.read!(VirtualMachine, id: vm_id)
        assert Atom.to_string(profile) == expected
        assert length(Ledger.read!(Operation, vm_id: vm_id)) == 1
        assert length(Ledger.read!(Reservation, vm_id: vm_id)) == 1
        assert length(Ledger.read!(Request, user_id: c.actor.id, request_id: key)) == 1
        assert durable_profile_rows() == admitted_rows
      end

      {:ok, deletion} =
        Compute.lifecycle(%{vm_id: vm_id, kind: :delete, idempotency_key: Ash.UUID.generate()},
          actor: c.actor
        )

      assert {:ok, _} = ingest(c.host.id, outcome(deletion, 1, :deleted))
    end
  end

  test "relocation commands select the destination, replay, poll and cancel by receipt", c do
    assert {:ok, created} = command(c, "new --name moving --request-id moving-create")
    [provision] = Ledger.read!(Operation, id: created.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(provision, 1, :running))
    destination = host_fixture()

    assert {:ok, moving} =
             command(c, "relocate moving --request-id moving-request --no-wait")

    assert moving.status == "accepted"
    assert moving.result["id"] == created.result["id"]
    refute Map.has_key?(moving.result, "host_id")
    refute Map.has_key?(moving.result, "destination_host_id")
    assert [relocation] = Ledger.read!(Relocation, id: moving.operation_id)
    assert relocation.source_host_id == c.host.id
    assert relocation.destination_host_id == destination.host.id

    assert {:ok, replay} =
             command(c, "relocate moving --request-id moving-request --timeout 300 --json")

    assert replay.operation_id == moving.operation_id
    assert length(Ledger.read!(Relocation, vm_id: created.result["id"])) == 1
    assert {:ok, shown} = command(c, "request show moving-request")
    assert shown.operation_id == moving.operation_id
    assert shown.status == "accepted"

    assert {:error, retry_error} =
             command(c, "request retry moving-request --request-id moving-retry --no-wait")

    assert Exception.message(retry_error) =~ "relocation_retry_unavailable"

    assert {:ok, cancelled} =
             command(c, "request cancel moving-request --request-id moving-cancel --no-wait")

    assert cancelled.operation_id == moving.operation_id
    assert cancelled.status == "accepted"
    assert cancelled.result["phase"] == "restoring_source"
    refute cancelled.result["cancellable"]
    assert {:ok, original} = command(c, "request show moving-request")
    assert original.status == "accepted"
    assert {:ok, cancellation} = command(c, "request show moving-cancel")
    assert cancellation.status == "accepted"
  end

  test "explicit retry retains a capacity-refused clone and its failed SSH receipt", c do
    assert {:ok, created} =
             command(
               c,
               "new --profile standard --cpu 2 --name capacity-source --request-id source"
             )

    [provision] = Ledger.read!(Operation, id: created.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(provision, 1, :running))
    Ledger.update!(c.host, :report, %{capacity: capacity(3), reported_at: Ledger.now()})
    holds = Ledger.read!(Reservation)
    operations = Ledger.read!(Operation)

    assert {:ok, queued} = command(c, "clone capacity-source --request-id copy --no-wait")
    id = queued.operation_id
    destination = queued.result["destination_vm_id"]
    assert {:ok, _} = Marshall.Compute.CloneCoordinator.advance(id)
    assert {:ok, failed} = command(c, "request show copy")
    assert failed.status == "failed"
    assert failed.result["failure"] == "insufficient_capacity"
    assert failed.result["active"] == false
    assert Ledger.read!(Reservation) == holds
    assert Ledger.read!(Operation) == operations
    assert Ledger.read!(VirtualMachine, id: destination) == []

    assert {:ok, retried} = command(c, "request retry copy --request-id retry-copy --no-wait")
    assert retried.status == "accepted"
    assert retried.operation_id == id
    assert retried.result["destination_vm_id"] == destination
    assert retried.result["phase"] == "queued"
    assert {:ok, ^failed} = command(c, "request show copy")
    assert length(Ledger.read!(Marshall.Compute.CloneRequest)) == 1

    Ledger.update!(c.host, :report, %{capacity: capacity(5), reported_at: Ledger.now()})
    assert {:ok, _} = Marshall.Compute.CloneCoordinator.advance(id)
    assert [_] = Ledger.read!(VirtualMachine, id: destination)
    assert {:ok, replay} = command(c, "request retry copy --request-id retry-copy --no-wait")
    assert replay.operation_id == id
    assert replay.result["destination_vm_id"] == destination
    assert replay.result["active"]
    assert {:ok, ^failed} = command(c, "request show copy")
  end

  test "image defaults cannot exceed the disk maximum", c do
    manifest = Map.put(image_manifest(), "minimum_disk_bytes", 501 * 1_073_741_824)
    {:ok, image} = Marshall.Compute.Images.register(manifest, "oversized-fixture")

    Ledger.update!(c.host, :report, %{
      inventory: Map.put(c.report.inventory, "images", [image.id])
    })

    Application.put_env(:marshall, :default_image_id, image.id)
    assert {:error, _} = command(c, "new --request-id oversized-default")
    assert Ledger.read!(VirtualMachine) == []
    assert Ledger.read!(Reservation) == []
    assert Ledger.read!(Operation) == []
    assert Ledger.read!(Request) == []
  end

  test "new provisions into an authorized selected team", c do
    {:ok, team} =
      Marshall.Teams.create_team(
        %{name: "ssh-team-" <> binary_part(Ash.UUID.generate(), 0, 8), idempotency_key: "team"},
        actor: c.actor
      )

    assert {:ok, receipt} = command(c, "new --team #{team.name} --request-id team-machine")
    assert [%{team_id: team_id}] = Ledger.read!(VirtualMachine, id: receipt.result["id"])
    assert team_id == team.id
  end

  test "team create receipts pin retries and reject another creator without a receipt", c do
    outsider = user()
    other = session_for(c, outsider, <<3::256>>)
    name = "receipt-team-" <> binary_part(Ash.UUID.generate(), 0, 8)
    request = "team create #{name} --request-id pinned-team"

    assert {:ok, created} = command(c, request)
    assert {:ok, ^created} = command(c, request)
    assert {:error, _} = command(c, "team create #{name}-changed --request-id pinned-team")
    assert {:error, _} = command(other, request)
    assert [] == Ledger.read!(Request, user_id: outsider.id)
    [team] = Ledger.read!(Marshall.Teams.Team, id: created.result["id"])
    assert {:ok, :ok} = Ledger.transaction(fn -> Ledger.archive!(team, :archive) end)

    assert {:ok, replacement} = command(other, request)
    refute replacement.result["id"] == created.result["id"]
    assert {:ok, ^created} = command(c, request)

    assert [%{user_id: owner_id, role: :owner}] =
             Ledger.read!(Marshall.Teams.TeamMember, team_id: replacement.result["id"])

    assert owner_id == outsider.id
  end

  test "team commands dispatch create, show, membership and every transfer action", c do
    target = user()
    target_client = session_for(c, target, <<2::256>>)
    name = "dispatch-team-" <> binary_part(Ash.UUID.generate(), 0, 8)

    assert {:ok, created} = command(c, "team create #{name} --request-id team-create")
    team_id = created.result["id"]
    assert OverallsProtocol.uuid?(team_id)

    assert {:ok, shown} = command(c, "team show #{name}")
    assert %{"members" => [%{"role" => "owner", "user_id" => owner_id}]} = shown.result
    assert owner_id == c.actor.id

    assert {:ok, added} =
             command(
               c,
               "team member add #{name} #{target.email} member --request-id member-add"
             )

    assert added.result["team_id"] == team_id
    assert added.result["user_id"] == target.id

    assert {:ok, removed} =
             command(c, "team member remove #{name} #{target.email} --request-id member-remove")

    assert removed.result["role"] == "removed"

    assert {:ok, _} =
             command(
               c,
               "team member add #{name} #{target.email} member --request-id member-readd"
             )

    assert {:ok, offered} =
             command(c, "team transfer offer #{name} #{target.email} --request-id offer-cancel")

    assert {:ok, cancelled} =
             command(
               c,
               "team transfer cancel #{offered.result["transfer_id"]} --request-id cancel"
             )

    assert cancelled.result["state"] == "cancelled"

    assert {:ok, offered} =
             command(c, "team transfer offer #{name} #{target.email} --request-id offer-decline")

    assert {:ok, declined} =
             command(
               target_client,
               "team transfer decline #{offered.result["transfer_id"]} --request-id decline"
             )

    assert declined.result["state"] == "declined"

    assert {:ok, offered} =
             command(c, "team transfer offer #{name} #{target.email} --request-id offer-accept")

    assert {:ok, accepted} =
             command(
               target_client,
               "team transfer accept #{offered.result["transfer_id"]} --request-id accept"
             )

    assert accepted.result["state"] == "accepted"
    assert Marshall.Teams.Coordinator.roles(team_id).owner == target.id
  end

  test "accepted requests pin resources and defaults across a lost reply", c do
    assert {:ok, first} = command(c, "new --name pinned --request-id create-1 --no-wait")
    assert first.status == "accepted"
    Application.put_env(:marshall, :default_image_id, "sha256:" <> String.duplicate("f", 64))

    assert {:ok, ^first} =
             command(c, "new --name pinned --request-id create-1 --json --timeout 30")

    assert {:error, error} = command(c, "new --name other --request-id create-1")
    assert Exception.message(error) =~ "idempotency_conflict"
    assert length(Ledger.read!(VirtualMachine)) == 1
    assert length(Ledger.read!(Reservation)) == 1
    assert length(Ledger.read!(Operation)) == 1
    assert length(Ledger.read!(Request)) == 1

    assert length(
             Oban.Testing.all_enqueued(
               repo: Marshall.Repo,
               worker: Marshall.Compute.Workers.Dispatch
             )
           ) == 1
  end

  property "retries, acknowledgement and reordered evidence preserve one physical result", c do
    check all(succeeded? <- boolean(), retries <- integer(1..4), max_runs: 8) do
      id = Ash.UUID.generate()
      {:ok, receipt} = command(c, "new --request-id #{id}")

      for _ <- 1..retries do
        assert {:ok, ^receipt} = command(c, "new --request-id #{id} --json --no-wait")
      end

      [operation] = Ledger.read!(Operation, id: receipt.operation_id)
      assert length(Ledger.read!(Operation, vm_id: operation.vm_id)) == 1
      Ledger.update!(operation, :acknowledge, %{})
      assert {:ok, %{status: "accepted"}} = command(c, "request show #{id}")
      state = if succeeded?, do: :running, else: :failed
      event = outcome(operation, 2, state)
      assert {:ok, _} = ingest(c.host.id, event)
      stale = outcome(operation, 1, if(succeeded?, do: :failed, else: :running))
      assert {:ok, _} = ingest(c.host.id, stale)
      expected = if succeeded?, do: "succeeded", else: "failed"
      assert {:ok, %{status: ^expected}} = command(c, "request show #{id}")
      [completed] = Ledger.read!(Operation, id: operation.id)
      assert completed.completion_outcome_id == event.id

      {:ok, deletion} =
        Compute.lifecycle(
          %{vm_id: operation.vm_id, kind: :delete, idempotency_key: Ash.UUID.generate()},
          actor: c.actor
        )

      assert {:ok, _} = ingest(c.host.id, outcome(deletion, 3, :deleted))
      assert {:ok, %{status: ^expected}} = command(c, "request show #{id}")
    end
  end

  test "name reuse cannot retarget an old delete receipt", c do
    {:ok, created} = command(c, "new --name reusable --request-id new-1")
    {:ok, deleted} = command(c, "rm reusable --request-id remove-1")
    [operation] = Ledger.read!(Operation, id: deleted.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(operation, 1, :deleted))
    assert {:ok, finished} = command(c, "request show remove-1")
    assert finished.status == "succeeded"
    {:ok, successor} = command(c, "new --name reusable --request-id new-2")
    refute successor.result["id"] == created.result["id"]
    assert {:ok, ^finished} = command(c, "rm reusable --request-id remove-1")
    [vm] = Ledger.read!(VirtualMachine, id: successor.result["id"])
    assert vm.desired_state == :running
    assert {:ok, %{status: "superseded"}} = command(c, "request show new-1")
  end

  test "a receipt failure rolls back allocation, operation and Oban job", c do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "ALTER TABLE ssh_requests ADD CONSTRAINT reject_fixture_receipt CHECK (request_id <> 'reject-fixture')",
      []
    )

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, _} = command(c, "new --request-id reject-fixture")
      end)

    refute logs =~ "VM capacity reserved"
    refute logs =~ "SSH command admitted"
    assert Ledger.read!(Request) == []
    assert Ledger.read!(VirtualMachine) == []
    assert Ledger.read!(Reservation) == []
    assert Ledger.read!(Operation) == []

    assert Oban.Testing.all_enqueued(
             repo: Marshall.Repo,
             worker: Marshall.Compute.Workers.Dispatch
           ) == []

    successful =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = command(c, "new --request-id committed-fixture")
      end)

    assert successful =~ "SSH command admitted"
    [vm] = Ledger.read!(VirtualMachine)
    member = user()

    sharing =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, _} =
                 command(
                   c,
                   "share add #{vm.id} #{member.email} viewer --request-id reject-fixture"
                 )
      end)

    refute sharing =~ "VM access request applied"
    assert Ledger.read!(Marshall.Access.Grant, vm_id: vm.id) == []
    assert Ledger.read!(Marshall.Access.Change, vm_id: vm.id) == []
  end

  test "current key authority applies to polls while accepted work survives revocation", c do
    {:ok, created} = command(c, "new --request-id continuing")
    assert {:ok, removed} = command(c, "ssh-key remove #{c.key.id} --request-id revoke-self")
    assert removed.status == "succeeded"
    assert {:error, _} = command(c, "request show continuing")
    [operation] = Ledger.read!(Operation, id: created.operation_id)
    assert operation.status == :pending
    assert {:ok, _} = ingest(c.host.id, outcome(operation, 1, :running))
    {:ok, _} = SSH.add_key(%{public_key: public_key(<<2::256>>)}, actor: c.actor)

    {:ok, fresh} =
      SSH.open_session(%{gateway_token: c.gateway_token, public_key: public_key(<<2::256>>)},
        actor: SystemActor.compute()
      )

    assert {:ok, %{status: "succeeded"}} =
             command(%{c | session_token: fresh.session_token}, "request show continuing")

    assert {:ok, ^removed} =
             command(
               %{c | session_token: fresh.session_token},
               "ssh-key remove #{c.key.id} --request-id revoke-self"
             )
  end

  test "read commands and command actions reject caller-supplied account authority", c do
    assert {:ok, %{result: %{id: id, guest_username: username, public_key: public_key}}} =
             command(c, "whoami")

    assert id == c.actor.id
    [account] = Ledger.read!(Marshall.Accounts.GuestAccount, user_id: c.actor.id)
    assert username == account.username
    assert username == "u#{account.uid}"
    assert public_key == c.public_key
    assert {:ok, %{result: %{"images" => [_]}}} = command(c, "images")
    assert {:error, _} = SSH.execute(params(c, "whoami"), actor: c.actor)
    malformed = Map.update!(params(c, "whoami"), :command, &Map.put(&1, "owner_id", c.actor.id))
    assert {:error, _} = SSH.execute(malformed, actor: SystemActor.compute())
  end

  test "sharing retries do not reapply a grant, and revoked members cannot poll old work", c do
    member = user()
    email = to_string(member.email)
    {:ok, created} = command(c, "new --profile standard --name shared --request-id owned")
    {:ok, shared} = command(c, "share add shared #{email} manager --request-id grant-1")
    key = public_key(<<3::256>>)
    {:ok, _} = SSH.add_key(%{public_key: key}, actor: member)

    {:ok, opened} =
      SSH.open_session(%{gateway_token: c.gateway_token, public_key: key},
        actor: SystemActor.compute()
      )

    peer = %{c | session_token: opened.session_token}
    {:ok, stop} = command(peer, "stop shared --request-id member-stop")
    assert {:error, _} = command(c, "request show member-stop")
    assert {:ok, _} = command(c, "share remove shared #{email} --request-id remove-member")
    assert {:ok, ^shared} = command(c, "share add shared #{email} manager --request-id grant-1")
    assert {:error, _} = command(peer, "request show member-stop")
    assert {:error, _} = command(peer, "show shared")
    [operation] = Ledger.read!(Operation, id: stop.operation_id)
    assert operation.vm_id == created.result["id"]
    assert operation.status == :pending
  end

  test "omitted sizes respect image minima and explicit undersized requests fail", c do
    manifest =
      Map.merge(image_manifest(), %{
        "minimum_memory_bytes" => 805_306_368,
        "minimum_disk_bytes" => 3_221_225_472
      })

    {:ok, image} = Marshall.Compute.Images.register(manifest, "larger-fixture")

    Ledger.update!(c.host, :report, %{
      inventory: Map.put(c.report.inventory, "images", [image.id])
    })

    Application.put_env(:marshall, :default_image_id, image.id)
    assert {:error, _} = command(c, "new --memory 512 --request-id too-small")
    assert Ledger.read!(Request) == []
    assert {:ok, reply} = command(c, "new --request-id minimums")
    assert reply.result["memory_bytes"] == 805_306_368
    assert reply.result["disk_bytes"] == 3_221_225_472
    assert reply.result["image_id"] == image.id
  end

  # Complete durable intent inventory: raw rows of every table that lifecycle,
  # receipt, sharing or audit admission may touch. Refusals compare byte-equal.
  @oracle_tables [
    "compute_virtual_machines",
    "compute_virtual_machines_versions",
    "compute_workload_placements",
    "compute_reservations",
    "compute_operations",
    "compute_physical_outcomes",
    "compute_network_addresses",
    "ssh_requests",
    "access_grants",
    "access_grants_versions",
    "access_changes",
    "account_admin_events"
  ]

  @spec oracle_inventory() :: %{String.t() => [map()]}
  defp oracle_inventory do
    Map.new(@oracle_tables, fn table ->
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT to_jsonb(r) AS row FROM #{table} r ORDER BY id",
          [],
          log: false
        )

      {table, Enum.map(rows, fn [row] -> row end)}
    end)
  end

  @spec dispatch_count() :: non_neg_integer()
  defp dispatch_count do
    length(
      Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: Marshall.Compute.Workers.Dispatch)
    )
  end

  # Both host and pool report timestamps feed admission freshness; each
  # generated history refreshes them rather than racing the five-second window.
  @spec refresh_reports(map()) :: :ok
  defp refresh_reports(c) do
    Ledger.update!(c.host, :report, %{reported_at: Ledger.now()})
    Ledger.update!(c.pool, :report, %{reported_at: Ledger.now()})
    :ok
  end

  @spec history_actors(map()) :: %{atom() => map()}
  defp history_actors(c) do
    admin =
      Ash.Seed.seed!(Marshall.Accounts.User, %{
        email: "history-admin-" <> binary_part(Ash.UUID.generate(), 0, 12) <> "@example.test",
        administrator: true
      })

    %{
      owner: c,
      member: session_for(c, user(), :crypto.strong_rand_bytes(32)),
      revoked: session_for(c, user(), :crypto.strong_rand_bytes(32)),
      stranger: session_for(c, user(), :crypto.strong_rand_bytes(32)),
      admin: session_for(c, admin, :crypto.strong_rand_bytes(32))
    }
  end

  # OSS grants arrive through the real share entry; Customer's stale manager and
  # revoked grants are seeded to prove profile policy confers nothing durably.
  @spec wire_membership(map(), map(), String.t(), String.t(), String.t()) :: :ok
  defp wire_membership(c, actors, "oss", name, vm_id) do
    email = &to_string(&1.actor.email)

    assert {:ok, _} =
             command(
               c,
               "share add #{name} #{email.(actors.member)} manager --request-id #{Ash.UUID.generate()}"
             )

    assert {:ok, _} =
             command(
               c,
               "share add #{name} #{email.(actors.revoked)} manager --request-id #{Ash.UUID.generate()}"
             )

    assert {:ok, _} =
             command(
               c,
               "share remove #{name} #{email.(actors.revoked)} --request-id #{Ash.UUID.generate()}"
             )

    [vm] = Ledger.read!(VirtualMachine, id: vm_id)
    assert Marshall.Access.Authorization.allowed?(vm, actors.member.actor, "manage")
    refute Marshall.Access.Authorization.allowed?(vm, actors.revoked.actor, "read")
    refute Marshall.Access.Authorization.allowed?(vm, actors.admin.actor, "manage")
    :ok
  end

  defp wire_membership(c, actors, "customer", _name, vm_id) do
    Ledger.create!(Grant, :grant, %{
      vm_id: vm_id,
      user_id: actors.member.actor.id,
      granted_by_id: c.actor.id,
      role: :manager
    })

    Ledger.create!(Grant, :grant, %{
      vm_id: vm_id,
      user_id: actors.revoked.actor.id,
      granted_by_id: c.actor.id,
      role: :manager
    })

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: vm_id,
                 email: to_string(actors.revoked.actor.email),
                 role: :revoked,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.actor
             )

    [vm] = Ledger.read!(VirtualMachine, id: vm_id)
    assert [%{role: :manager}] = Ledger.read!(Grant, vm_id: vm_id)

    for refused <- [:member, :revoked, :admin], action <- ["read", "manage"] do
      refute Marshall.Access.Authorization.allowed?(vm, actors[refused].actor, action)
    end

    assert Marshall.Access.Authorization.allowed?(vm, actors.owner.actor, "manage")
    :ok
  end

  # @cc [owner:ghuntley,label:verification;security] lifecycle-refusal-zero-ledger-oracle
  # A refused entry MUST leave the complete durable inventory byte-identical,
  # enqueue no dispatch and persist no receipt for its request key.
  @spec refused_entry(map(), atom(), atom(), String.t()) :: :ok
  defp refused_entry(actors, refused, attempt, name) do
    before = oracle_inventory()
    dispatches = dispatch_count()
    key = Ash.UUID.generate()
    actor = actors[refused]

    text =
      case attempt do
        :show -> "show #{name}"
        kind -> "#{lifecycle_command(kind)} #{name} --request-id #{key}"
      end

    assert {:error, error} = command(actor, text)
    assert Exception.message(error) =~ "forbidden"
    assert {:error, _} = command(actor, "request show #{key}")
    assert [] = Ledger.read!(Request, user_id: actor.actor.id, request_id: key)
    assert dispatch_count() == dispatches
    assert oracle_inventory() == before
    :ok
  end

  @spec lifecycle_command(:stop | :start | :rm) :: String.t()
  defp lifecycle_command(:stop), do: "stop"
  defp lifecycle_command(:start), do: "start"
  defp lifecycle_command(:rm), do: "rm"

  # @cc [owner:ghuntley,label:verification;concurrency] lifecycle-accepted-delta-oracle
  # An accepted lifecycle command MUST add exactly one pending operation bound to
  # the actor, VM, kind and request key, one accepted request, one VM version and
  # one dispatch; replay and changed-kind reuse MUST NOT add durable work.
  @spec accepted_lifecycle(map(), map(), atom(), String.t(), String.t(), pos_integer()) ::
          %{key: String.t(), operation_id: String.t()}
  defp accepted_lifecycle(c, actor, kind, name, vm_id, sequence) do
    if kind == :start, do: refresh_reports(c)
    text = "#{lifecycle_command(kind)} #{name}"
    key = Ash.UUID.generate()
    [%{generation: generation}] = Ledger.read!(VirtualMachine, id: vm_id)
    before = oracle_inventory()
    dispatches = dispatch_count()

    assert {:ok, receipt} = command(actor, "#{text} --request-id #{key}")
    assert receipt.status == "accepted"
    assert OverallsProtocol.uuid?(receipt.operation_id)

    assert {:ok, ^receipt} = command(actor, "#{text} --request-id #{key} --no-wait --json")

    other_kind = Enum.find([:start, :stop], &(&1 != kind)) |> lifecycle_command()

    assert {:error, conflict} =
             command(actor, "#{other_kind} #{name} --request-id #{key} --no-wait")

    assert Exception.message(conflict) =~ "idempotency_conflict"
    assert dispatch_count() == dispatches + 1

    assert_accepted_delta(
      before,
      oracle_inventory(),
      actor.actor.id,
      key,
      receipt,
      vm_id,
      kind,
      generation
    )

    [operation] = Ledger.read!(Operation, id: receipt.operation_id)
    terminal = %{stop: :stopped, start: :running, rm: :deleted}[kind]

    event = outcome(operation, sequence, terminal)

    event =
      if terminal == :stopped, do: Map.put(event, :compute_empty, true), else: event

    assert {:ok, _} = ingest(c.host.id, event)
    assert {:ok, settled} = command(actor, "request show #{key}")
    assert settled.status == "succeeded"
    assert settled.operation_id == receipt.operation_id
    assert {:ok, ^settled} = command(actor, "request show #{key}")
    assert_settled(kind, vm_id)
    %{key: key, operation_id: receipt.operation_id}
  end

  @spec assert_accepted_delta(
          map(),
          map(),
          String.t(),
          String.t(),
          map(),
          String.t(),
          atom(),
          pos_integer()
        ) :: :ok
  defp assert_accepted_delta(
         before,
         after_accept,
         actor_id,
         key,
         receipt,
         vm_id,
         kind,
         generation
       ) do
    static = [
      "compute_workload_placements",
      "compute_network_addresses",
      "compute_physical_outcomes",
      "access_grants",
      "access_grants_versions",
      "access_changes",
      "account_admin_events"
    ]

    static = if kind == :start, do: static, else: ["compute_reservations" | static]
    for table <- static, do: assert(after_accept[table] == before[table])

    reservations_before = Map.new(before["compute_reservations"], &{&1["id"], &1})
    reservations_after = Map.new(after_accept["compute_reservations"], &{&1["id"], &1})
    assert Map.keys(reservations_after) == Map.keys(reservations_before)

    if kind == :start do
      for {id, row} <- reservations_before do
        after_row = reservations_after[id]

        if row["vm_id"] == vm_id do
          assert after_row["compute_held"] == true
          assert after_row["startup_compute_held"] == true
          assert after_row["disk_held"] == row["disk_held"]
        else
          assert after_row == row
        end
      end
    end

    new_operations = after_accept["compute_operations"] -- before["compute_operations"]

    assert [new_operation] = new_operations
    assert new_operation["vm_id"] == vm_id
    assert new_operation["requested_by_id"] == actor_id
    assert OverallsProtocol.uuid?(new_operation["request_key"])
    assert new_operation["status"] == "pending"
    assert new_operation["kind"] == if(kind == :rm, do: "delete", else: Atom.to_string(kind))
    operation_id = new_operation["id"]
    assert operation_id == receipt.operation_id

    assert [
             %{
               "request_id" => ^key,
               "user_id" => ^actor_id,
               "vm_id" => ^vm_id,
               "operation_id" => ^operation_id,
               "status" => "accepted"
             }
           ] = after_accept["ssh_requests"] -- before["ssh_requests"]

    assert [_version] =
             after_accept["compute_virtual_machines_versions"] --
               before["compute_virtual_machines_versions"]

    vms_before = Map.new(before["compute_virtual_machines"], &{&1["id"], &1})
    vms_after = Map.new(after_accept["compute_virtual_machines"], &{&1["id"], &1})
    assert Map.keys(vms_after) == Map.keys(vms_before)
    expected_desired = %{stop: "stopped", start: "running", rm: "deleted"}[kind]

    for {id, row} <- vms_before do
      after_row = vms_after[id]

      if id == vm_id do
        assert after_row["generation"] == generation + 1
        assert after_row["desired_state"] == expected_desired
      else
        assert after_row == row
      end
    end

    :ok
  end

  @spec assert_settled(:stop | :start | :rm, String.t()) :: :ok
  defp assert_settled(:stop, vm_id) do
    [vm] = Ledger.read!(VirtualMachine, id: vm_id)
    assert vm.observed_state == :stopped and vm.desired_state == :stopped
    [reservation] = Ledger.read!(Reservation, vm_id: vm_id)
    refute reservation.compute_held
    assert reservation.disk_held
  end

  defp assert_settled(:start, vm_id) do
    [vm] = Ledger.read!(VirtualMachine, id: vm_id)
    assert vm.observed_state == :running and vm.desired_state == :running
    [reservation] = Ledger.read!(Reservation, vm_id: vm_id)
    assert reservation.compute_held and reservation.disk_held
  end

  defp assert_settled(:rm, vm_id) do
    assert [] = Ledger.read!(VirtualMachine, id: vm_id)
    assert [%{archived_at: %DateTime{}}] = Ledger.history!(VirtualMachine, id: vm_id)
    [reservation] = Ledger.read!(Reservation, vm_id: vm_id)
    refute reservation.compute_held
    refute reservation.disk_held
  end

  # A settled deletion leaves owner-readable receipts pinned to the archived
  # machine; other actors stay refused without durable work, and a name-reused
  # successor gets its own identity rather than the retained receipt.
  @spec close_history(map(), map(), String.t(), String.t(), map()) :: :ok
  defp close_history(c, actors, name, vm_id, settled) do
    rm_key = Map.fetch!(settled, :rm).key
    rm_operation = Map.fetch!(settled, :rm).operation_id
    [rm_request] = Ledger.read!(Request, request_id: rm_key)
    rm_actor = if rm_request.user_id == actors.member.actor.id, do: :member, else: :owner

    for refused <- [:member, :revoked, :stranger, :admin], refused != rm_actor do
      before = oracle_inventory()
      assert {:error, _} = command(actors[refused], "request show #{rm_key}")
      assert {:error, _} = command(actors[refused], "show #{name}")

      assert {:error, _} =
               command(actors[refused], "stop #{name} --request-id #{Ash.UUID.generate()}")

      assert oracle_inventory() == before
    end

    assert {:ok, removed} = command(actors[rm_actor], "request show #{rm_key}")
    assert removed.status == "succeeded"
    assert removed.result["id"] == vm_id

    assert {:ok, ^removed} =
             command(actors[rm_actor], "rm #{name} --request-id #{rm_key} --no-wait --json")

    refresh_reports(c)

    assert {:ok, successor} =
             command(c, "new --name #{name} --request-id #{Ash.UUID.generate()}")

    refute successor.result["id"] == vm_id

    assert {:ok, %{status: "succeeded", result: %{"id" => ^vm_id}}} =
             command(actors[rm_actor], "request show #{rm_key}")

    assert {:ok, shown} = command(c, "show #{name}")
    assert shown.result["id"] == successor.result["id"]
    [successor_provision] = Ledger.read!(Operation, id: successor.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(successor_provision, 1, :running))

    assert {:ok, cleanup} =
             command(c, "rm #{name} --request-id #{Ash.UUID.generate()} --no-wait")

    assert cleanup.operation_id != rm_operation
    [removal] = Ledger.read!(Operation, id: cleanup.operation_id)
    assert {:ok, _} = ingest(c.host.id, outcome(removal, 2, :deleted))
    [successor_reservation] = Ledger.read!(Reservation, vm_id: successor.result["id"])
    refute successor_reservation.compute_held
    refute successor_reservation.disk_held

    assert {:ok, %{status: "succeeded", result: %{"id" => ^vm_id}}} =
             command(actors[rm_actor], "request show #{rm_key}")

    :ok
  end

  defp command(c, text), do: SSH.execute(params(c, text), actor: SystemActor.compute())

  # Compare the sandbox's complete durable identities, including VMs archived by
  # earlier histories: returning the old receipt must not hide a second machine.
  @spec durable_profile_rows() :: %{
          vms: [Ash.UUID.t()],
          operations: [Ash.UUID.t()],
          reservations: [Ash.UUID.t()],
          requests: [Ash.UUID.t()]
        }
  defp durable_profile_rows do
    %{
      vms: VirtualMachine |> Ledger.history!([]) |> Enum.map(& &1.id) |> Enum.sort(),
      operations: Operation |> Ledger.read!() |> Enum.map(& &1.id) |> Enum.sort(),
      reservations: Reservation |> Ledger.read!() |> Enum.map(& &1.id) |> Enum.sort(),
      requests: Request |> Ledger.read!() |> Enum.map(& &1.id) |> Enum.sort()
    }
  end

  defp session_for(c, actor, bytes) do
    key = public_key(bytes)
    {:ok, _} = SSH.add_key(%{public_key: key}, actor: actor)

    {:ok, session} =
      SSH.open_session(%{gateway_token: c.gateway_token, public_key: key},
        actor: SystemActor.compute()
      )

    %{c | actor: actor, session_token: session.session_token}
  end

  defp params(c, text) do
    {:ok, command} = OverallsProtocol.SSHCommand.parse(text)

    %{
      gateway_token: c.gateway_token,
      session_token: c.session_token,
      command: command |> Jason.encode!() |> Jason.decode!()
    }
  end

  defp public_key(bytes) do
    blob = <<11::32, "ssh-ed25519", 32::32, bytes::binary>>
    "ssh-ed25519 " <> Base.encode64(blob)
  end

  defp ingest(host, event) do
    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    Ledger.transaction(fn ->
      Ledger.lock!(Host, host)
      Outcomes.ingest_locked!(host, [event])
    end)
  end

  defp outcome(operation, sequence, state) do
    %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
      operation_id: operation.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation,
      sequence: sequence,
      state: state,
      compute_empty: state in [:failed, :deleted],
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: if(state == :failed, do: :execution_failed, else: :none)
    }
  end
end
