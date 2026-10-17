defmodule MarshallWeb.ProvisionerAPITest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  import Marshall.LillySocket, only: [reply: 2]
  alias Marshall.LillySocket

  alias Marshall.Compute.{
    Credentials,
    Host,
    HostSession,
    Ledger,
    Operation,
    Reservation,
    VirtualMachine
  }

  setup do
    fixture = host_fixture()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: user())
    {:ok, issued} = Credentials.rotate(fixture.host.id, 3600)
    Map.merge(fixture, %{issued: issued, vm: vm})
  end

  test "session retries are idempotent and old opens cannot replace a successor", %{
    issued: issued,
    host: host
  } do
    session = open(issued.token)
    assert open(issued.token, session["session_id"]) == session
    successor = open(issued.token)
    assert successor["epoch"] > session["epoch"]

    conn =
      send_api(issued.token, "sessions", %{"version" => 4, "session_id" => session["session_id"]})

    assert reply(conn, 409) == %{"error" => "stale_connection"}
    assert [%{connection_session_id: id}] = Ledger.read!(Host, id: host.id)
    assert id == successor["session_id"]
    assert reply(exchange(issued.token, session), 409) == %{"error" => "stale_connection"}
  end

  # @cc [owner:ghuntley,label:verification;security] generated-consumed-session-ratchet
  # Every fresh session MUST advance the durable epoch exactly once. Retrying a
  # current nonce MUST be idempotent, while every superseded nonce MUST remain
  # unable to open or exchange after any later takeover.
  property "generated takeovers never readmit consumed session nonces" do
    check all(takeovers <- integer(2..5), newest_first? <- boolean(), max_runs: 8) do
      fixture = host_fixture()
      {:ok, issued} = Credentials.rotate(fixture.host.id, 3600)
      [initial] = Ledger.read!(Host, id: fixture.host.id)

      history =
        Enum.reduce(1..takeovers, [], fn _, previous ->
          session = open(issued.token)
          assert session["epoch"] == initial.connection_epoch + length(previous) + 1
          assert open(issued.token, session["session_id"]) == session
          assert %{"commands" => []} = exchange(issued.token, session) |> reply(200)

          [current] = Ledger.read!(Host, id: fixture.host.id)
          assert current.connection_epoch == session["epoch"]
          assert current.connection_session_id == session["session_id"]

          stale_sessions = if newest_first?, do: previous, else: Enum.reverse(previous)

          for stale <- stale_sessions do
            before_refusal = Ledger.read!(Host, id: fixture.host.id)

            assert %{"error" => "stale_connection"} =
                     send_api(issued.token, "sessions", %{
                       "version" => 4,
                       "session_id" => stale["session_id"]
                     })
                     |> reply(409)

            assert %{"error" => "stale_connection"} =
                     exchange(issued.token, stale) |> reply(409)

            assert Ledger.read!(Host, id: fixture.host.id) == before_refusal
          end

          sessions = Ledger.read!(HostSession, host_id: fixture.host.id)
          expected = [session | previous]

          assert MapSet.new(sessions, &{&1.id, &1.epoch}) ==
                   MapSet.new(expected, &{&1["session_id"], &1["epoch"]})

          expected
        end)

      assert length(history) == takeovers
    end
  end

  test "reports, acknowledgements and commands are scoped to the authenticated host", context do
    %{issued: issued, host: host, vm: vm, report: report} = context
    session = open(issued.token)

    response =
      exchange(issued.token, session, %{"report" => OverallsProtocol.encode_report(report)})
      |> reply(200)

    assert {:ok, [command]} = OverallsProtocol.Execution.commands(response["commands"])
    assert command.vm_id == vm.id
    assert command.host_id == host.id
    assert [%{reported_at: %DateTime{}, report_sequence: 1}] = Ledger.read!(Host, id: host.id)

    response =
      exchange(issued.token, session, %{"acknowledgements" => [command.id]}) |> reply(200)

    assert {:ok, [^command]} = OverallsProtocol.Execution.commands(response["commands"])
    assert [%{status: :acknowledged}] = Ledger.read!(Operation, id: command.id)
    assert [%{observed_state: :pending}] = Ledger.read!(VirtualMachine, id: vm.id)
    assert [%{compute_held: true, disk_held: true}] = Ledger.read!(Reservation, vm_id: vm.id)

    other = host_fixture()
    {:ok, other_credential} = Credentials.rotate(other.host.id, 3600)
    other_session = open(other_credential.token)

    assert %{"commands" => []} =
             exchange(other_credential.token, other_session) |> reply(200)

    assert %{"error" => "invalid_acknowledgement"} =
             exchange(other_credential.token, other_session, %{"acknowledgements" => [command.id]})
             |> reply(400)

    assert {:ok, :ok} = Credentials.revoke(host.id)

    revoked_logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        assert %{"error" => "unauthorized"} =
                 exchange(issued.token, session) |> reply(401)
      end)

    # The socket refuses a revoked credential at upgrade, through the host
    # credential check's catalogued event.
    assert revoked_logs =~ "event=host.auth_rejected"
    # Closed catalogued reasons survive authentication filtering; the revoked
    # host credential never does.
    assert revoked_logs =~ "reason=unauthorized"
    refute revoked_logs =~ issued.token
  end

  test "invalid acknowledgements roll back an otherwise valid capacity report", %{
    issued: issued,
    host: host,
    report: report
  } do
    session = open(issued.token)

    conn =
      exchange(issued.token, session, %{
        "report" => OverallsProtocol.encode_report(report),
        "acknowledgements" => [Ash.UUID.generate()]
      })

    assert reply(conn, 400) == %{"error" => "invalid_acknowledgement"}
    assert [%{reported_at: nil, report_sequence: 0}] = Ledger.read!(Host, id: host.id)
  end

  property "a poisoned command rolls back fresh reports until its operation is removed", %{
    host: setup_host
  } do
    Ledger.update!(setup_host, :configure, %{enabled: false})

    check all(
            retries <- integer(1..4),
            acknowledge? <- boolean(),
            max_runs: 8
          ) do
      fixture = host_fixture()
      owner = user()
      {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
      {:ok, issued} = Credentials.rotate(fixture.host.id, 3600)
      session = open(issued.token)

      first_report = %{fixture.report | sampled_at: DateTime.utc_now(), sequence: 1}

      response =
        exchange(issued.token, session, %{
          "report" => OverallsProtocol.encode_report(first_report)
        })
        |> reply(200)

      assert {:ok, [command]} = OverallsProtocol.Execution.commands(response["commands"])
      assert command.vm_id == vm.id
      [baseline] = Ledger.read!(Host, id: fixture.host.id)
      assert Marshall.Compute.HostLiveness.capacity_fresh?(baseline.reported_at, Ledger.now())

      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        ~s(UPDATE compute_operations SET command_snapshot = '{"version":3}'::jsonb WHERE id = $1),
        [Ecto.UUID.dump!(command.id)],
        log: false
      )

      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "UPDATE compute_hosts SET reported_at = clock_timestamp() - interval '6 seconds' WHERE id = $1",
        [Ecto.UUID.dump!(fixture.host.id)],
        log: false
      )

      [stale] = Ledger.read!(Host, id: fixture.host.id)
      refute Marshall.Compute.HostLiveness.capacity_fresh?(stale.reported_at, Ledger.now())

      for attempt <- 1..retries do
        report = %{
          fixture.report
          | sampled_at: DateTime.utc_now(),
            sequence: attempt + 1
        }

        acknowledgements = if acknowledge?, do: [command.id], else: []

        assert reply(
                 exchange(issued.token, session, %{
                   "report" => OverallsProtocol.encode_report(report),
                   "acknowledgements" => acknowledgements
                 }),
                 409
               ) == %{"error" => "reconciliation_required"}

        assert [%{report_sequence: 1, reported_at: reported_at}] =
                 Ledger.read!(Host, id: fixture.host.id)

        assert reported_at == stale.reported_at
        refute Marshall.Compute.HostLiveness.capacity_fresh?(reported_at, Ledger.now())
        assert [%{status: :pending}] = Ledger.read!(Operation, id: command.id)
      end

      assert {:ok, stop} =
               Marshall.Compute.lifecycle(
                 %{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
                 actor: owner
               )

      assert [%{status: :cancelled}] = Ledger.read!(Operation, id: command.id)

      recovery_report = %{
        fixture.report
        | sampled_at: DateTime.utc_now(),
          sequence: retries + 2
      }

      response =
        exchange(issued.token, session, %{
          "report" => OverallsProtocol.encode_report(recovery_report)
        })
        |> reply(200)

      assert {:ok, [recovery_command]} = OverallsProtocol.Execution.commands(response["commands"])
      assert recovery_command.id == stop.id

      assert [%{report_sequence: recovery_sequence, reported_at: %DateTime{} = recovered_at}] =
               Ledger.read!(Host, id: fixture.host.id)

      assert recovery_sequence == retries + 2
      assert Marshall.Compute.HostLiveness.capacity_fresh?(recovered_at, Ledger.now())
      [host] = Ledger.read!(Host, id: fixture.host.id)
      Ledger.update!(host, :configure, %{enabled: false})
    end
  end

  test "unsupported body versions fail before a control transaction", %{issued: issued} do
    assert %{"error" => "unsupported_version"} =
             send_api(issued.token, "sessions", %{"version" => 99}) |> reply(426)
  end

  property "malformed v4 documents are permanent client errors on every action", %{
    issued: issued,
    host: host
  } do
    actions = [
      "sessions",
      "exchange",
      "clone",
      "inception",
      "relocation_keys",
      "relocation_source",
      "relocation_probe",
      "relocation_receive",
      "relocation_import",
      "relocation_readiness",
      "relocation_cleanup",
      "relocation_key_retirement",
      "relocation_revocation",
      "relocation_destination_revocation",
      "relocation_destination_cleanup",
      "relocation_snapshot_cleanup"
    ]

    check all(
            body <-
              member_of([
                %{},
                %{"version" => 4},
                %{"x" => 1},
                %{"version" => 4, "session_id" => "not-a-uuid"},
                %{"version" => 4, "session_id" => 1, "epoch" => []}
              ]),
            max_runs: 12
          ) do
      [before_host] = Ledger.read!(Host, id: host.id)

      for action <- actions do
        assert send_api(issued.token, action, body) |> reply(400) == %{
                 "error" => "invalid_message"
               }
      end

      assert Ledger.read!(Host, id: host.id) == [before_host]
    end
  end

  property "version refusals preserve host authority until a valid session opens", %{
    issued: issued,
    host: host,
    vm: vm
  } do
    check all(
            body_version <- member_of([0, 1, 2, 3, "4", nil]),
            max_runs: 20
          ) do
      [before_host] = Ledger.read!(Host, id: host.id)
      before_operations = Ledger.read!(Operation, vm_id: vm.id)
      session_id = Ash.UUID.generate()

      for {action, body} <- [
            {"sessions", %{"version" => body_version, "session_id" => session_id}},
            {"exchange",
             %{
               "version" => body_version,
               "session_id" => session_id,
               "epoch" => before_host.connection_epoch,
               "report" => nil,
               "acknowledgements" => [],
               "outcomes" => []
             }}
          ] do
        assert send_api(issued.token, action, body) |> reply(426) == %{
                 "error" => "unsupported_version"
               }

        assert Ledger.read!(Host, id: host.id) == [before_host]
        assert Ledger.read!(Operation, vm_id: vm.id) == before_operations
      end

      assert %{"epoch" => expected_epoch, "session_id" => ^session_id} =
               open(issued.token, session_id)

      assert expected_epoch == before_host.connection_epoch + 1
    end
  end

  test "unreadable encrypted credentials fail closed without ciphertext diagnostics", %{
    issued: issued
  } do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE compute_host_credentials SET encrypted_secret = $1 WHERE id = $2",
      ["unreadable-test-ciphertext", Ecto.UUID.dump!(issued.id)],
      log: false
    )

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Marshall.Control.Services.Lilly.authenticate(issued.token) == :unavailable

        conn =
          %{build_conn(:get, "/api/control/v1") | scheme: :https}
          |> put_req_header("overalls-control", "1")
          |> put_req_header("overalls-service", "lilly")
          |> put_req_header("authorization", "Bearer " <> issued.token)
          |> MarshallWeb.ControlAPI.call([])

        assert conn.status == 503
      end)

    refute logs =~ "unreadable-test-ciphertext"
  end

  defp open(token, id \\ Ash.UUID.generate()) do
    send_api(token, "sessions", %{"version" => 4, "session_id" => id}) |> reply(200)
  end

  defp exchange(token, session, overrides \\ %{}) do
    send_api(
      token,
      "exchange",
      Map.merge(
        %{
          "version" => 4,
          "session_id" => session["session_id"],
          "epoch" => session["epoch"],
          "report" => nil,
          "acknowledgements" => [],
          "outcomes" => []
        },
        overrides
      )
    )
  end

  defp send_api(token, action, body) do
    body =
      if action == "sessions" and body["version"] == 4 do
        [id | _] = String.split(token, ":")
        [credential] = Ledger.read!(Marshall.Compute.HostCredential, id: id)
        [host] = Ledger.read!(Host, id: credential.host_id)
        Map.put(body, "machine_id", host.machine_id)
      else
        body
      end

    # Control requests run over the control socket (ADR-0142).
    LillySocket.request(token, action, body)
  end
end
