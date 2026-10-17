defmodule Marshall.Ingress.PrivateHistoryTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{HostReports, Ledger, Operation, ProvisionerControl, VirtualMachine}
  alias Marshall.Ingress
  alias Marshall.Ingress.{Endpoint, Token, WebStream}
  @moduletag capture_log: true

  @type role :: :web | :viewer | :operator | :manager | :revoked
  @type operation :: {:direct, role()} | {:team, :member | :admin | :removed}
  @type fixture :: %{
          owner: User.t(),
          member: User.t(),
          token: String.t(),
          vm: VirtualMachine.t(),
          team_id: String.t(),
          service_token: String.t(),
          label: String.t(),
          host: Marshall.Compute.Host.t(),
          report: OverallsProtocol.report(),
          connection: %{session_id: String.t(), epoch: pos_integer()}
        }
  @type model :: %{
          direct: role(),
          team: boolean(),
          live: String.t() | nil,
          cookie: String.t() | nil,
          closed: [String.t()]
        }
  @type grant :: %{
          ticket: String.t(),
          ttl: non_neg_integer(),
          user_id: String.t() | nil,
          binding: %{
            vm_id: String.t(),
            host_id: String.t(),
            placement_id: String.t(),
            execution_epoch: pos_integer(),
            generation: pos_integer(),
            label: String.t(),
            port: pos_integer(),
            session_id: String.t(),
            service: :web
          }
        }
  @type exchange :: %{
          service_token: String.t(),
          ticket: String.t(),
          code: String.t(),
          state: String.t()
        }

  # @cc [owner:ghuntley,label:verification;security] private-web-authority-histories
  # The independent role model MUST determine approval, exchange, fresh opening
  # and renewal decisions after real direct/team actions. A code approved before
  # withdrawal MUST recheck authority on exchange. Gateway-style explicit close
  # after refusal MUST permanently fence that ticket even after re-addition.
  # Synthetic execution reports establish control admission, not network closure.
  property "private browser admission and renewal follow combined sharing histories" do
    check all(
            port <- member_of([0, 3000, 9999]),
            tail <-
              list_of(
                one_of([
                  map(member_of([:web, :viewer, :operator, :manager, :revoked]), &{:direct, &1}),
                  map(member_of([:member, :admin, :removed]), &{:team, &1})
                ]),
                max_length: 8
              ),
            max_runs: 12
          ) do
      c = fixture()

      operations =
        [
          {:direct, :web},
          {:direct, :viewer},
          {:direct, :operator},
          {:direct, :manager},
          {:team, :member},
          {:direct, :revoked},
          {:team, :removed},
          {:team, :admin},
          {:team, :removed},
          {:direct, :web}
        ] ++ tail

      Enum.reduce(
        Enum.with_index(operations, 3),
        %{direct: :revoked, team: false, live: nil, cookie: nil, closed: []},
        fn {operation, sequence}, model ->
          fresh_report(c, sequence)
          pending = if allowed?(model), do: approve(c, port)
          model = change(c, model, operation)
          expected = allowed?(model)

          if pending do
            result = Ingress.exchange_web_login(pending, actor: SystemActor.compute())
            assert match?({:ok, _}, result) == expected
          end

          if model.cookie do
            opening = open(c, model.cookie, port)
            assert match?({:ok, _}, opening) == expected

            case opening do
              {:ok, opened} ->
                assert {:ok, _} =
                         Ingress.close_web(renewal(c, opened.ticket),
                           actor: SystemActor.compute()
                         )

              {:error, _} ->
                :ok
            end
          end

          request = begin_login(c, port)

          approval =
            Ingress.authorize_web_login(%{ticket: request.ticket, login_token: c.token},
              actor: c.member
            )

          assert match?({:ok, _}, approval) == expected

          model =
            if model.live do
              result = Ingress.renew_web(renewal(c, model.live), actor: SystemActor.compute())
              assert match?({:ok, _}, result) == expected

              if expected do
                model
              else
                assert {:ok, %{closed: true}} =
                         Ingress.close_web(renewal(c, model.live), actor: SystemActor.compute())

                %{model | live: nil, closed: [model.live | model.closed]}
              end
            else
              model
            end

          for closed <- model.closed do
            assert {:error, _} =
                     Ingress.renew_web(renewal(c, closed), actor: SystemActor.compute())
          end

          if expected do
            cookie = cookie(c, port)
            model = %{model | cookie: cookie}
            # Exact host/app credentials cannot authorize another private port.
            assert {:error, _} = open(c, cookie, if(port == 3000, do: 9999, else: 3000))
            assert {:ok, opened} = open(c, cookie, port)
            assert opened.user_id == c.member.id
            assert opened.binding.port == if(port == 0, do: 8080, else: port)
            assert opened.ttl > 0 and opened.ttl <= 30_000

            if model.live do
              assert {:ok, _} =
                       Ingress.close_web(renewal(c, opened.ticket), actor: SystemActor.compute())

              model
            else
              %{model | live: opened.ticket}
            end
          else
            assert {:error, _} = open(c, nil, port)
            model
          end
        end
      )
    end
  end

  # @cc [owner:ghuntley,label:verification;security] private-web-stale-bindings
  # Private stream renewal MUST retain its policy/execution/login and live lease
  # bindings. Actual endpoint configuration and sign-out exercise public actions;
  # expiry and generation changes below are explicitly synthetic fault injection.
  # A new login may authorize a fresh stream but MUST NOT revive the closed one.
  property "private streams retain exact policy, execution and login bindings" do
    check all(
            boundary <- member_of([:policy, :execution, :signout, :close, :expire]),
            port <- member_of([0, 3000, 9999]),
            max_runs: 20
          ) do
      c = fixture()

      change(
        c,
        %{direct: :revoked, team: false, live: nil, cookie: nil, closed: []},
        {:direct, :web}
      )

      credential = cookie(c, port)
      assert {:ok, opened} = open(c, credential, port)
      request = renewal(c, opened.ticket)
      assert {:ok, _} = Ingress.renew_web(request, actor: SystemActor.compute())

      case boundary do
        :policy ->
          [endpoint] = Ledger.read!(Endpoint, vm_id: c.vm.id)

          assert {:ok, _} =
                   Ingress.configure_endpoint(
                     %{
                       vm_id: c.vm.id,
                       expected_revision: endpoint.policy_revision,
                       primary_port: 8081,
                       visibility: :private
                     },
                     actor: c.owner
                   )

        :execution ->
          [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
          Ledger.intent!(vm, %{generation: vm.generation + 1})

        :signout ->
          conn =
            Plug.Test.conn(:get, "/sign-out")
            |> Plug.Test.init_test_session(%{"user_token" => c.token})
            |> Plug.Conn.assign(:current_user, c.member)
            |> Phoenix.Controller.fetch_flash()
            |> MarshallWeb.AuthController.sign_out(%{})

          assert conn.status == 302

        :close ->
          assert {:ok, _} = Ingress.close_web(request, actor: SystemActor.compute())

        :expire ->
          [stream] = Ledger.read!(WebStream, id: opened.binding.session_id)
          Ledger.update!(stream, :renew, %{expires_at: DateTime.add(Ledger.now(), -1)})
      end

      assert {:error, _} = Ingress.renew_web(request, actor: SystemActor.compute())
      if boundary == :signout, do: assert(match?({:error, _}, open(c, credential, port)))
      assert {:ok, _} = Ingress.close_web(request, actor: SystemActor.compute())
      c = %{c | token: Marshall.TerminalFixtures.user_token(c.member)}

      if boundary != :execution do
        assert {:ok, _} = open(c, cookie(c, port), port)
      end

      assert {:error, _} = Ingress.renew_web(request, actor: SystemActor.compute())
    end
  end

  @spec allowed?(model()) :: boolean()
  defp allowed?(model), do: model.direct != :revoked or model.team

  @spec change(fixture(), model(), operation()) :: model()
  defp change(c, model, {:direct, role}) do
    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(c.member.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    %{model | direct: role}
  end

  defp change(c, model, {:team, role}) do
    assert {:ok, _} =
             Marshall.Teams.set_team_member(
               %{
                 team_id: c.team_id,
                 email: to_string(c.member.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    %{model | team: role != :removed}
  end

  @spec begin_login(fixture(), non_neg_integer()) :: %{ticket: String.t(), state: String.t()}
  defp begin_login(c, port) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.encode16(:crypto.hash(:sha256, state), case: :lower)

    assert {:ok, started} =
             Ingress.begin_web_login(
               %{
                 service_token: c.service_token,
                 label: c.label,
                 app_port: port,
                 state_digest: digest
               },
               actor: SystemActor.compute()
             )

    %{ticket: started.ticket, state: state}
  end

  @spec approve(fixture(), non_neg_integer()) :: exchange()
  defp approve(c, port) do
    started = begin_login(c, port)

    assert {:ok, approved} =
             Ingress.authorize_web_login(%{ticket: started.ticket, login_token: c.token},
               actor: c.member
             )

    %{
      service_token: c.service_token,
      ticket: started.ticket,
      state: started.state,
      code: approved.code
    }
  end

  @spec cookie(fixture(), non_neg_integer()) :: String.t()
  defp cookie(c, port) do
    assert {:ok, result} =
             Ingress.exchange_web_login(approve(c, port), actor: SystemActor.compute())

    result.cookie
  end

  @spec open(fixture(), String.t() | nil, non_neg_integer()) :: {:ok, grant()} | {:error, term()}
  defp open(c, cookie, port),
    do:
      Ingress.open_web(
        %{service_token: c.service_token, label: c.label, app_port: port, cookie: cookie},
        actor: SystemActor.compute()
      )

  @spec renewal(fixture(), String.t()) :: %{service_token: String.t(), stream_token: String.t()}
  defp renewal(c, ticket), do: %{service_token: c.service_token, stream_token: ticket}

  @spec fresh_report(fixture(), pos_integer()) :: :ok
  defp fresh_report(c, sequence) do
    assert {:ok, :ok} =
             HostReports.ingest(c.host.id, c.connection.epoch, %{
               c.report
               | sequence: sequence,
                 sampled_at: Ledger.now()
             })

    :ok
  end

  @spec fixture() :: fixture()
  defp fixture do
    for host <- Ledger.read!(Marshall.Compute.Host),
        do: Ledger.update!(host, :configure, %{enabled: false})

    source = Marshall.TerminalFixtures.terminal_fixture()
    member = Marshall.ComputeFixtures.user()

    {:ok, team} =
      Marshall.Teams.create_team(
        %{name: "private-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
        actor: source.owner
      )

    {:ok, vm} =
      Marshall.Compute.provision(
        Marshall.ComputeFixtures.request(%{team_id: team.id, profile: :oss, vcpu: 1}),
        actor: source.owner
      )

    [operation] = Ledger.read!(Operation, vm_id: vm.id)

    {:ok, _} =
      ProvisionerControl.exchange_execution(
        source.credential.token,
        Map.merge(source.connection, %{
          report: %{source.report | sequence: 2, sampled_at: Ledger.now()},
          acknowledgements: [],
          outcomes: [
            %{
              id: Ash.UUID.generate(),
              vm_id: vm.id,
              placement_id: vm.current_placement_id,
              execution_epoch: vm.execution_epoch,
              operation_id: operation.id,
              generation: vm.generation,
              sequence: 1,
              state: :running,
              compute_empty: false,
              disk_present: true,
              cleanup_complete: false,
              reason: :none
            }
          ]
        })
      )

    {service_token, _} = Token.issue()

    {:ok, _} =
      Ingress.configure_service(
        %{
          name: "private-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: vm.host_id,
          token: service_token,
          addresses: ["192.0.2.9"]
        },
        actor: SystemActor.compute()
      )

    [endpoint] = Ledger.read!(Endpoint, vm_id: vm.id)

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    {:ok, _} =
      Ingress.publish_host_key(%{token: service_token, public_key: key},
        actor: SystemActor.compute()
      )

    {:ok, _} =
      Ingress.configure_endpoint(
        %{
          vm_id: vm.id,
          expected_revision: endpoint.policy_revision,
          primary_port: 8080,
          visibility: :private
        },
        actor: source.owner
      )

    %{
      owner: source.owner,
      member: member,
      token: Marshall.TerminalFixtures.user_token(member),
      vm: vm,
      team_id: team.id,
      service_token: service_token,
      label: endpoint.label,
      host: source.host,
      report: source.report,
      connection: source.connection
    }
  end
end
