defmodule Marshall.Access.SharingMatrixDistributedTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  require Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.Access
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger}
  alias Marshall.Repo
  alias Marshall.SharingMatrixFixture, as: Fixture

  @moduletag :distributed
  @moduletag timeout: 120_000

  @type role :: :manager | :operator | :viewer | :web | :revoked

  # @cc [owner:ghuntley,label:verification] committed-fixture-suite-preservation
  # Every journey MUST restore its complete pre-test row inventory, including
  # historical rows. ExUnit reports this independent teardown check separately
  # from a body failure; it MUST NOT replace the original assertion.
  setup do
    {before, images_before} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {Marshall.CommittedFixtureInventory.snapshot(), Cleanup.fixture_image_ids()}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        # This test interval owns only the fixture image IDs absent before the
        # test. Fixture cleanup leaves image disposal to this boundary.
        Cleanup.images!(Cleanup.fixture_image_ids() -- images_before)
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-three-independent-peers
  # Share mutations and entry executions MUST run on three fresh Marshall BEAMs
  # with separate Repo pools and Cedar handles sharing only committed
  # PostgreSQL; the runner is not a replica.
  setup_all do
    peers =
      Enum.map(
        [:marshall_matrix_1, :marshall_matrix_2, :marshall_matrix_3],
        fn name ->
          peer =
            start_supervised!(%{
              id: name,
              start:
                {:peer, :start_link,
                 [
                   %{
                     name: String.to_atom("#{name}_#{System.pid()}"),
                     connection: :standard_io,
                     args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
                     wait_boot: 30_000
                   }
                 ]},
              restart: :temporary
            })

          node = :peer.call(peer, :erlang, :node, [])
          :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

          config =
            for {app, _, _} <- Application.loaded_applications(),
                app not in [:kernel, :stdlib, :elixir, :logger],
                do: {app, Application.get_all_env(app)}

          :ok = :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])

          repo_config =
            Application.fetch_env!(:marshall, Repo)
            |> Keyword.put(:pool, DBConnection.ConnectionPool)
            |> Keyword.put(:pool_size, 4)

          :ok =
            :peer.call(peer, Application, :put_env, [
              :marshall,
              Repo,
              repo_config,
              [persistent: true]
            ])

          :ok =
            :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])

          {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
          {peer, node}
        end
      )

    assert length(Enum.uniq(Enum.map(peers, &elem(&1, 1)))) == 3
    %{peers: Enum.map(peers, &elem(&1, 0))}
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-cross-peer-withdrawal
  # A share mutation committed on one peer MUST decide SSH and private web
  # entry results observed on the other two peers, and one committed revocation
  # MUST close renewal and reopening on every peer without reviving closed
  # tokens.
  test "share mutation on one peer decides SSH and web entries on two other peers",
       %{peers: [first, second, third]} do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert [] = Enum.filter(Ledger.read!(Host), & &1.enabled)
      fixture = Fixture.create(disable_others: false)
      assert fixture.vm.host_id == fixture.host.id

      Cleanup.protect [first, second, third] do
        assert {:ok, _} = mutate(first, fixture, :operator)

        fresh(fixture)
        {:ok, ssh} = open_ssh(second, fixture)

        fresh(fixture)
        assert {:ok, _} = renew_ssh(third, fixture, ssh.ticket)

        fresh(fixture)

        assert {:ok, %{items: [%{id: vm_id}]}} =
                 :peer.call(
                   third,
                   Marshall.Compute,
                   :list_vms,
                   [%{}, [actor: fixture.member]],
                   30_000
                 )

        assert vm_id == fixture.vm.id

        fresh(fixture)
        {ticket, state} = begin_web(first, fixture)

        assert {:ok, approved} =
                 :peer.call(
                   second,
                   Marshall.Ingress,
                   :authorize_web_login,
                   [
                     %{ticket: ticket, login_token: fixture.member_token},
                     [actor: fixture.member]
                   ],
                   30_000
                 )

        fresh(fixture)

        assert {:ok, %{cookie: cookie}} =
                 exchange_web(third, fixture, Map.put(approved, :state, state))

        fresh(fixture)
        assert {:ok, web} = open_web(first, fixture, cookie)
        assert web.user_id == fixture.member.id

        fresh(fixture)
        assert {:ok, _} = renew_web(second, fixture, web.ticket)

        # Demotion on the third peer: SSH closes everywhere, web survives.
        assert {:ok, _} = mutate(third, fixture, :web)
        fresh(fixture)
        assert {:error, _} = renew_ssh(second, fixture, ssh.ticket)
        fresh(fixture)
        assert {:error, _} = open_ssh(third, fixture)
        assert {:error, _} = open_terminal_remote(first, fixture)
        fresh(fixture)
        assert {:ok, _} = renew_web(first, fixture, web.ticket)

        assert {:ok, %{items: []}} =
                 :peer.call(
                   third,
                   Marshall.Compute,
                   :list_vms,
                   [%{}, [actor: fixture.member]],
                   30_000
                 )

        # One committed withdrawal closes web renewal and reopening; the
        # ordinary closes succeed exactly once and the tokens never revive.
        assert {:ok, _} = mutate(second, fixture, :revoked)
        fresh(fixture)
        assert {:error, _} = renew_web(third, fixture, web.ticket)
        fresh(fixture)
        assert {:error, _} = open_web(second, fixture, cookie)
        fresh(fixture)
        assert {:ok, %{closed: true}} = close_web(third, fixture, web.ticket)
        fresh(fixture)
        assert {:ok, %{closed: true}} = close_ssh(first, fixture, ssh.ticket)
        fresh(fixture)
        assert {:error, _} = renew_web(first, fixture, web.ticket)
        assert {:error, _} = renew_ssh(second, fixture, ssh.ticket)

        # Re-granting reopens fresh entries on every peer without reviving
        # the closed tokens.
        assert {:ok, _} = mutate(first, fixture, :manager)
        fresh(fixture)
        assert {:error, _} = renew_web(third, fixture, web.ticket)
        assert {:error, _} = renew_ssh(third, fixture, ssh.ticket)
        fresh(fixture)
        {:ok, fresh_ssh} = open_ssh(second, fixture)
        fresh(fixture)
        assert {:ok, _} = renew_ssh(first, fixture, fresh_ssh.ticket)
        assert {:ok, %{closed: true}} = close_ssh(third, fixture, fresh_ssh.ticket)
      after
        Fixture.cleanup(fixture)
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-peer-schedule
  # Generated schedules MUST place each share mutation and each entry probe on
  # arbitrary distinct peers while the independent matrix oracle decides every
  # expected result from the committed role alone.
  @tag :hegel
  test "generated peer schedules keep every entry on the committed matrix",
       %{peers: peers} do
    check all(
            tail <-
              list_of(
                tuple(
                  {member_of([:manager, :operator, :viewer, :web, :revoked]), integer(0..2),
                   integer(0..2), member_of([:ssh_open, :web_authorize, :inventory])}
                ),
                min_length: 2,
                max_length: 4
              ),
            test_cases: 3
          ) do
      schedule =
        [
          {:operator, 0, 1, :ssh_open},
          {:manager, 1, 2, :web_authorize},
          {:viewer, 2, 0, :web_authorize},
          {:viewer, 0, 1, :ssh_open},
          {:viewer, 2, 0, :inventory},
          {:web, 1, 2, :web_authorize},
          {:web, 0, 1, :inventory},
          {:web, 2, 0, :ssh_open},
          {:revoked, 1, 2, :web_authorize}
        ] ++ tail

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert [] = Enum.filter(Ledger.read!(Host), & &1.enabled)
        fixture = Fixture.create(disable_others: false)

        # No in-flight RPCs exist between iterations: all calls are serially
        # awaited. Peers therefore stay alive across a failing iteration so the
        # shrink evidence keeps its original oracle instead of losing the peers.
        Cleanup.protect do
          for {role, mutator, prober, entry} <- schedule do
            assert {:ok, _} = mutate(Enum.at(peers, mutator), fixture, role)

            probe = Enum.at(peers, prober)

            case entry do
              :ssh_open ->
                fresh(fixture)

                if grants?(role, :ssh) do
                  assert {:ok, ssh} = open_ssh(probe, fixture)
                  assert {:ok, %{closed: true}} = close_ssh(probe, fixture, ssh.ticket)
                else
                  assert {:error, _} = open_ssh(probe, fixture)
                end

              :web_authorize ->
                fresh(fixture)
                {ticket, _state} = begin_web(probe, fixture)

                result =
                  :peer.call(
                    probe,
                    Marshall.Ingress,
                    :authorize_web_login,
                    [
                      %{ticket: ticket, login_token: fixture.member_token},
                      [actor: fixture.member]
                    ],
                    30_000
                  )

                if grants?(role, :web) do
                  assert {:ok, _} = result
                else
                  assert {:error, _} = result
                end

              :inventory ->
                assert {:ok, %{items: items}} =
                         :peer.call(
                           probe,
                           Marshall.Compute,
                           :list_vms,
                           [%{}, [actor: fixture.member]],
                           30_000
                         )

                assert Enum.any?(items, &(&1.id == fixture.vm.id)) == grants?(role, :inventory)
            end
          end
        after
          Fixture.cleanup(fixture)
        end
      end)
    end
  end

  # Independent literal matrix: identical contract to the sandboxed history.
  # The Cedar web policy admits viewers; SSH stays operator/manager-only.
  @spec grants?(role(), :ssh | :web | :inventory) :: boolean()
  defp grants?(:manager, _), do: true
  defp grants?(:operator, _), do: true
  defp grants?(:viewer, capability), do: capability in [:inventory, :web]
  defp grants?(:web, capability), do: capability == :web
  defp grants?(:revoked, _), do: false

  @spec mutate(pid(), Fixture.t(), role()) :: {:ok, term()} | {:error, term()}
  defp mutate(peer, fixture, role) do
    :peer.call(
      peer,
      Access,
      :set_access,
      [
        %{
          vm_id: fixture.vm.id,
          email: to_string(fixture.member.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        [actor: fixture.owner]
      ],
      30_000
    )
  end

  @spec open_ssh(pid(), Fixture.t()) :: {:ok, map()} | {:error, term()}
  defp open_ssh(peer, fixture),
    do:
      :peer.call(
        peer,
        Marshall.Ingress,
        :open_ssh,
        [
          %{
            service_token: fixture.service_token,
            public_key: fixture.member_public_key,
            label: fixture.label
          },
          [actor: SystemActor.compute()]
        ],
        30_000
      )

  @spec renew_ssh(pid(), Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp renew_ssh(peer, fixture, ticket),
    do:
      :peer.call(
        peer,
        Marshall.Ingress,
        :renew_ssh,
        [
          %{service_token: fixture.service_token, session_token: ticket},
          [actor: SystemActor.compute()]
        ],
        30_000
      )

  @spec close_ssh(pid(), Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp close_ssh(peer, fixture, ticket),
    do:
      :peer.call(
        peer,
        Marshall.Ingress,
        :close_ssh,
        [
          %{service_token: fixture.service_token, session_token: ticket},
          [actor: SystemActor.compute()]
        ],
        30_000
      )

  @spec begin_web(pid(), Fixture.t()) :: {String.t(), String.t()}
  defp begin_web(peer, fixture) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.encode16(:crypto.hash(:sha256, state), case: :lower)

    assert {:ok, started} =
             :peer.call(
               peer,
               Marshall.Ingress,
               :begin_web_login,
               [
                 %{
                   service_token: fixture.service_token,
                   label: fixture.label,
                   app_port: 0,
                   state_digest: digest
                 },
                 [actor: SystemActor.compute()]
               ],
               30_000
             )

    {started.ticket, state}
  end

  @spec exchange_web(pid(), Fixture.t(), map()) :: {:ok, map()} | {:error, term()}
  defp exchange_web(peer, fixture, approved),
    do:
      :peer.call(
        peer,
        Marshall.Ingress,
        :exchange_web_login,
        [
          %{
            service_token: fixture.service_token,
            ticket: approved.ticket,
            code: approved.code,
            state: approved.state
          },
          [actor: SystemActor.compute()]
        ],
        30_000
      )

  @spec open_web(pid(), Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp open_web(peer, fixture, cookie),
    do:
      :peer.call(
        peer,
        Marshall.Ingress,
        :open_web,
        [
          %{
            service_token: fixture.service_token,
            label: fixture.label,
            app_port: 0,
            cookie: cookie
          },
          [actor: SystemActor.compute()]
        ],
        30_000
      )

  @spec renew_web(pid(), Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp renew_web(peer, fixture, ticket),
    do:
      :peer.call(
        peer,
        Marshall.Ingress,
        :renew_web,
        [
          %{service_token: fixture.service_token, stream_token: ticket},
          [actor: SystemActor.compute()]
        ],
        30_000
      )

  @spec close_web(pid(), Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp close_web(peer, fixture, ticket),
    do:
      :peer.call(
        peer,
        Marshall.Ingress,
        :close_web,
        [
          %{service_token: fixture.service_token, stream_token: ticket},
          [actor: SystemActor.compute()]
        ],
        30_000
      )

  @spec open_terminal_remote(pid(), Fixture.t()) :: {:ok, term()} | {:error, term()}
  defp open_terminal_remote(peer, fixture),
    do:
      :peer.call(
        peer,
        Marshall.Terminal.Authority,
        :open_session,
        [fixture.vm, fixture.member, "root", "xterm-256color"],
        30_000
      )

  @spec fresh(Fixture.t()) :: :ok
  defp fresh(fixture) do
    [host] = Ledger.read!(Host, id: fixture.host.id)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    :ok
  end
end
