defmodule Marshall.Terminal.AttachmentHistoryTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties

  @moduletag capture_log: true

  alias Marshall.Compute.Ledger
  alias Marshall.Terminal.{Authority, Session, Sharing, Tickets}
  alias Marshall.TerminalAttachmentSocket, as: Socket
  alias Marshall.TerminalAttachmentStream, as: Stream

  @type role :: :viewer | :operator | :manager | :revoked
  @type boundary :: :grant | :login | :capability | :freshness | :execution | :kill
  @type trigger :: :input | :resize | :idle
  @type fixture :: %{
          host: Marshall.Compute.Host.t(),
          vm: Marshall.Compute.VirtualMachine.t(),
          owner: Marshall.Accounts.User.t(),
          member: Marshall.Accounts.User.t(),
          stream: pid()
        }

  # @cc [owner:ghuntley,label:verification] attachment-independent-mode-model
  # Expected attachment authority MUST come from generated user commands and
  # the creator/shared permission table, never from the SUT's authorization
  # answer. Tickets remain bounded by their issued mode and are consumed once.
  property "issued tickets compose current roles, explicit sharing and one-use socket lifetimes" do
    fixture = fixture()

    check all(
            steps <-
              list_of(
                tuple(
                  {member_of([:viewer, :operator, :manager, :revoked]),
                   member_of([:viewer, :operator, :manager, :revoked]), boolean(), boolean(),
                   integer(0..1_000_000)}
                ),
                min_length: 5,
                max_length: 8
              ),
            max_runs: 6
          ) do
      fresh(fixture)
      role(fixture, :operator)
      own = session(fixture, fixture.member)
      foreign = session(fixture, fixture.owner)
      token = Marshall.TerminalFixtures.user_token(fixture.member)
      {server, port} = server(fixture.member, token)

      try do
        # Mandatory decisive transitions accompany every generated history.
        steps =
          steps ++
            [
              {:viewer, :operator, true, true, 0},
              {:operator, :viewer, true, true, 1},
              {:operator, :revoked, true, true, 2},
              {:manager, :manager, false, true, 3},
              {:operator, :operator, false, false, 4}
            ]

        Enum.each(steps, fn {issued_role, current_role, creator?, shared?, cursor} ->
          fresh(fixture)
          role(fixture, :operator)
          :ok = Sharing.set(foreign, fixture.owner, to_string(fixture.member.email), :shared)
          role(fixture, issued_role)
          selected = if creator?, do: own, else: foreign

          if issued_role == :revoked do
            before = inventory(fixture)
            assert {:error, :forbidden} = Authority.ticket(selected, fixture.member)
            assert inventory(fixture) == before
          else
            assert {:ok, ticket} = Authority.ticket(selected, fixture.member)
            role(fixture, current_role)

            if not shared?,
              do:
                assert(
                  :ok =
                    Sharing.set(foreign, fixture.owner, to_string(fixture.member.email), :revoked)
                )

            allowed? = current_role != :revoked and (creator? or shared?)

            mode =
              if creator? and issued_role in [:operator, :manager] and
                   current_role in [:operator, :manager], do: :rw, else: :ro

            before = inventory(fixture)
            effects = Stream.effects(fixture.stream)
            client = Socket.connect(port, ticket, cursor)

            try do
              if allowed? do
                channel = attached(client, mode)

                assert [{:attach, process, request}] =
                         Enum.drop(Stream.effects(fixture.stream), length(effects))

                assert process == client.process

                assert request == %{
                         type: :attach,
                         cols: if(mode == :rw, do: 91, else: 0),
                         rows: if(mode == :rw, do: 31, else: 0),
                         vm_id: selected.vm_id,
                         placement_id: selected.placement_id,
                         execution_epoch: selected.execution_epoch,
                         guest_session_id: selected.guest_session_id,
                         mode: mode,
                         cursor: cursor
                       }

                assert :ok = Socket.send_frame(client, 2, "fixture-input")

                assert :ok =
                         Socket.send_frame(client, 1, ~s({"op":"resize","cols":103,"rows":37}))

                Socket.barrier(client)
                new_effects = Enum.drop(Stream.effects(fixture.stream), length(effects) + 1)

                if mode == :rw do
                  assert [{:input, ^channel, "fixture-input"}, {:resize, resize}] = new_effects

                  assert resize == %{
                           type: :resize,
                           vm_id: selected.vm_id,
                           placement_id: selected.placement_id,
                           execution_epoch: selected.execution_epoch,
                           guest_session_id: selected.guest_session_id,
                           cols: 103,
                           rows: 37
                         }
                else
                  assert new_effects == []
                end

                Socket.disconnect(client)
                assert List.last(Stream.effects(fixture.stream)) == {:gone, channel}
              else
                Socket.closed(client)
                assert Stream.effects(fixture.stream) == effects
              end

              # Audit and ticket receipts may change; VM/session/grant data must not.
              assert inventory(fixture) == before
              assert {:error, :invalid_ticket} = Tickets.consume(ticket)
              replay = Socket.connect(port, ticket, cursor)

              try do
                Socket.closed(replay)
              after
                Socket.dispose(replay)
              end
            after
              Socket.dispose(client)
            end
          end
        end)
      after
        stop_supervised!(server)
      end
    end
  end

  property "expired and foreign-actor tickets refuse a real attachment without relay dispatch" do
    fixture = fixture()
    own = session(fixture, fixture.member)
    foreign = session(fixture, fixture.owner)
    token = Marshall.TerminalFixtures.user_token(fixture.member)

    check all(cursor <- integer(0..1_000_000), expired_first? <- boolean(), max_runs: 4) do
      fresh(fixture)
      cases = if expired_first?, do: [:expired, :foreign], else: [:foreign, :expired]

      Enum.each(cases, fn kind ->
        {selected, issuer} =
          if kind == :expired, do: {own, fixture.member}, else: {foreign, fixture.owner}

        {:ok, ticket} = Authority.ticket(selected, issuer)

        if kind == :expired do
          # Inject elapsed ticket time without sleeping for the 30-second TTL.
          hash = :crypto.hash(:sha256, ticket) |> Base.encode16(case: :lower)

          %{num_rows: 1} =
            Ecto.Adapters.SQL.query!(
              Marshall.Repo,
              "UPDATE terminal_tickets SET expires_at = clock_timestamp() - interval '1 second' WHERE token_hash = $1",
              [hash],
              log: false
            )
        end

        before = inventory(fixture)
        effects = Stream.effects(fixture.stream)
        with_connection(fixture.member, token, ticket, cursor, &Socket.closed/1)
        assert Stream.effects(fixture.stream) == effects
        assert inventory(fixture) == before
        assert {:error, :invalid_ticket} = Tickets.consume(ticket)
      end)
    end
  end

  for trigger <- [:input, :resize, :idle] do
    @trigger trigger
    property "live #{@trigger} attachment closes across every authority boundary and needs a fresh socket" do
      fixture = fixture()

      check all(
              order <- list_of(integer(0..100), length: 6),
              cursor <- integer(0..1_000_000),
              max_runs: 3
            ) do
        boundaries =
          Enum.zip(order, [:grant, :login, :capability, :freshness, :execution, :kill])
          |> Enum.sort()
          |> Enum.map(&elem(&1, 1))

        Enum.each(boundaries, fn boundary ->
          fresh(fixture)
          role(fixture, :operator)
          selected = session(fixture, fixture.member)
          token = Marshall.TerminalFixtures.user_token(fixture.member)
          {:ok, jti, _} = Marshall.Accounts.Login.verify(token, fixture.member)
          {:ok, ticket} = Authority.ticket(selected, fixture.member)

          with_connection(fixture.member, token, ticket, cursor, fn client ->
            channel = attached(client, :rw)
            before_effects = Stream.effects(fixture.stream)
            revoke(fixture, selected, boundary, jti)

            # Committed authority changes notify their user and VM; the sandbox
            # never commits pg_notify, so deliver those hints as the relay would.
            # An idle viewer otherwise waits for its five-second backstop.
            if @trigger == :idle do
              for {kind, id} <- [{"user", fixture.member.id}, {"vm", fixture.vm.id}],
                  do: Marshall.Control.Hints.deliver(%{"kind" => kind, "id" => id})
            end

            before = inventory(fixture)
            trigger(client, @trigger)
            Socket.closed(client)
            assert Stream.effects(fixture.stream) == before_effects ++ [{:gone, channel}]
            assert inventory(fixture) == before
            assert {:error, :invalid_ticket} = Tickets.consume(ticket)

            # Sending after the monitored process ended cannot dispatch anything,
            # even when authority is explicitly restored for a new attachment.
            fresh(fixture)
            role(fixture, :operator)
            _ = Socket.send_frame(client, 2, "after-close")
            assert Stream.effects(fixture.stream) == before_effects ++ [{:gone, channel}]
          end)

          # Kill/execution changes retain old-session refusal. Restoration uses a
          # new explicit session in those cases; login restoration mints a new JTI.
          selected =
            if boundary in [:execution, :kill] do
              assert {:error, :unknown_session} = Authority.ticket(selected, fixture.member)
              session(fixture, fixture.member)
            else
              selected
            end

          token = Marshall.TerminalFixtures.user_token(fixture.member)
          {:ok, ticket} = Authority.ticket(selected, fixture.member)

          with_connection(fixture.member, token, ticket, cursor + 1, fn client ->
            channel = attached(client, :rw)
            assert :ok = Socket.send_frame(client, 2, "fresh-input")
            Socket.barrier(client)
            assert List.last(Stream.effects(fixture.stream)) == {:input, channel, "fresh-input"}
            Socket.disconnect(client)
          end)
        end)
      end
    end
  end

  @spec fixture() :: fixture()
  defp fixture do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    member = Marshall.ComputeFixtures.user()
    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, member, :operator)
    stream = start_supervised!({Stream, fixture.host.id}, id: make_ref())
    Map.merge(fixture, %{member: member, stream: stream})
  end

  @spec session(fixture(), Marshall.Accounts.User.t()) :: Session.t()
  defp session(fixture, actor) do
    {:ok, selected} = Authority.open_session(fixture.vm, actor, "root", "xterm-256color")
    selected
  end

  @spec server(Marshall.Accounts.User.t(), String.t()) :: {reference(), pos_integer()}
  defp server(actor, token) do
    id = make_ref()

    pid =
      start_supervised!(
        {Bandit,
         plug: {Socket, %{actor: actor, token: token, observer: self()}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: id
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {id, port}
  end

  @spec with_connection(
          Marshall.Accounts.User.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          (Socket.t() -> result)
        ) :: result
        when result: var
  defp with_connection(actor, token, ticket, cursor, fun) do
    {server, port} = server(actor, token)

    try do
      client = Socket.connect(port, ticket, cursor)

      try do
        fun.(client)
      after
        Socket.dispose(client)
      end
    after
      stop_supervised!(server)
    end
  end

  @spec attached(Socket.t(), :rw | :ro) :: pos_integer()
  defp attached(client, mode) do
    assert {1, bytes} = Socket.frame(client)
    assert %{"op" => "attached", "channel" => channel, "mode" => actual} = JSON.decode!(bytes)
    assert actual == Atom.to_string(mode)
    assert is_integer(channel) and channel > 0
    channel
  end

  @spec role(fixture(), role()) :: :ok
  defp role(fixture, role) do
    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, fixture.member, role)
    :ok
  end

  @spec fresh(fixture()) :: :ok
  defp fresh(fixture) do
    Ledger.update!(fixture.host, :report, %{
      reported_at: Ledger.now(),
      inventory: Map.put(fixture.host.inventory, "terminal_protocol", 2)
    })

    :ok
  end

  @spec revoke(fixture(), Session.t(), boundary(), String.t()) :: :ok
  defp revoke(fixture, selected, boundary, jti) do
    case boundary do
      :grant ->
        role(fixture, :viewer)

      :login ->
        assert :ok =
                 AshAuthentication.TokenResource.Actions.revoke_jti(
                   Marshall.Accounts.Token,
                   jti,
                   AshAuthentication.user_to_subject(fixture.member),
                   store_all_tokens?: true
                 )

      :capability ->
        Ledger.update!(fixture.host, :report, %{
          inventory: Map.put(fixture.host.inventory, "terminal_protocol", 1)
        })

      :freshness ->
        # Host loss: older than the host authority window. A merely late report
        # keeps attachments (ADR-0140), covered in the authority tests.
        Ledger.update!(fixture.host, :report, %{
          reported_at:
            DateTime.add(
              Ledger.now(),
              -(Marshall.Compute.HostLiveness.authority_ms() + 5_000),
              :millisecond
            )
        })

      :execution ->
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "UPDATE compute_virtual_machines SET execution_epoch = execution_epoch + 1 WHERE id = $1",
          [Ecto.UUID.dump!(fixture.vm.id)],
          log: false
        )

      :kill ->
        assert {:ok, _} = Marshall.Terminal.Termination.request(selected, fixture.member)
    end

    :ok
  end

  @spec trigger(Socket.t(), trigger()) :: :ok
  defp trigger(client, :input), do: Socket.send_frame(client, 2, "refused-input")

  defp trigger(client, :resize),
    do: Socket.send_frame(client, 1, ~s({"op":"resize","cols":99,"rows":29}))

  # Wait for the actual one-second timer: do not inject :check_authority.
  defp trigger(_client, :idle), do: :ok

  @spec inventory(fixture()) :: [[term()]]
  defp inventory(fixture) do
    queries = [
      "SELECT row_to_json(t)::text FROM compute_virtual_machines t WHERE id = $1 ORDER BY id",
      "SELECT row_to_json(t)::text FROM compute_operations t WHERE vm_id = $1 ORDER BY id",
      "SELECT row_to_json(t)::text FROM compute_reservations t WHERE vm_id = $1 ORDER BY id",
      "SELECT row_to_json(t)::text FROM access_grants t WHERE vm_id = $1 ORDER BY id",
      "SELECT row_to_json(t)::text FROM access_changes t WHERE vm_id = $1 ORDER BY id",
      "SELECT row_to_json(t)::text FROM access_grants_versions t WHERE version_source_id IN (SELECT id FROM access_grants WHERE vm_id = $1) ORDER BY id",
      "SELECT row_to_json(t)::text FROM compute_workload_placements t WHERE vm_id = $1 ORDER BY id",
      "SELECT row_to_json(t)::text FROM terminal_sessions t WHERE vm_id = $1 ORDER BY id",
      "SELECT row_to_json(t)::text FROM terminal_openings t WHERE vm_id = $1 ORDER BY id",
      "SELECT row_to_json(t)::text FROM terminal_grants t WHERE session_id IN (SELECT id FROM terminal_sessions WHERE vm_id = $1) ORDER BY id",
      "SELECT row_to_json(t)::text FROM terminal_sessions_versions t WHERE version_source_id IN (SELECT id FROM terminal_sessions WHERE vm_id = $1) ORDER BY id",
      "SELECT row_to_json(t)::text FROM terminal_grants_versions t WHERE version_source_id IN (SELECT id FROM terminal_grants WHERE session_id IN (SELECT id FROM terminal_sessions WHERE vm_id = $1)) ORDER BY id"
    ]

    Enum.map(queries, fn query ->
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(Marshall.Repo, query, [Ecto.UUID.dump!(fixture.vm.id)],
          log: false
        )

      rows
    end)
  end
end
