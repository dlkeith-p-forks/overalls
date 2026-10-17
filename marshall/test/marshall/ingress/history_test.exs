defmodule Marshall.Ingress.HistoryTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  @moduletag capture_log: true
  @moduletag timeout: 180_000
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{Endpoint, Publication, Route, Session, Token, WebCredential, WebStream}
  alias Marshall.IngressHistoryFixture, as: Fx
  import ExUnit.Assertions

  @kinds [:web, :ssh]
  @web_roles [:web, :viewer, :operator, :manager]
  @write_roles [:operator, :manager]

  setup do
    %{certificate: Fx.certificate(String.duplicate("a", 64), 1)}
  end

  # @cc [owner:ghuntley,label:verification;security] ingress-composed-history-oracle
  # One generated history threads endpoint configuration, gateway route
  # report/refresh/expiry, web and SSH open/renew/close, and every documented
  # withdrawal vector (visibility, sign-out, credential revoke, gateway rotation,
  # stop intent, execution epoch). The independent model MUST predict each exact
  # refusal class; durable PaperTrail rows MUST match the model's mutation counts
  # and never carry token material. Backdating and intent injection are synthetic
  # faults; everything else drives public or gateway actions.
  property "publication, lease and withdrawal histories follow one authority model", c do
    check all(
            tail <-
              list_of(operations(),
                min_length: 6,
                max_length: 16
              ),
            max_runs: 10
          ) do
      c = Fx.new(c.certificate)

      model =
        Enum.reduce(
          [
            {:configure, :public, 8080},
            :acknowledge,
            :report,
            :publish,
            {:open_web, :anonymous, 0},
            {:open_web, :member, 0},
            {:open_web, :member, 3000},
            {:open_ssh, :owner},
            {:open_ssh, :member}
            | tail
          ],
          initial(c),
          fn operation, model ->
            Fx.fresh_report(c, model.sequence)

            apply_step(current(c, model), model, operation)
            |> Map.update!(:sequence, &(&1 + 1))
          end
        )

      Fx.fresh_report(c, model.sequence + 1)
      audit(c, model)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] ingress-lease-exact-boundary
  # Renewal at the exact recorded instant counts as expired on both web streams
  # and SSH sessions; the documented expiry boundary is pinned by this oracle.
  test "renewal at the exact expiry instant is denied on web and SSH", context do
    c = Fx.new(context.certificate)
    Fx.fresh_report(c, 1)

    assert {:ok, _} = Fx.configure_endpoint(c, 8080, :public)
    {:ok, web} = Fx.open_web(c, nil, 0)
    {:ok, ssh} = Fx.open_ssh(c, :owner)

    for {kind, id} <- [{:web, web.binding.session_id}, {:ssh, ssh.binding.session_id}] do
      Fx.expire_stream(id, Ledger.now(), kind)

      assert :unauthorized ==
               Fx.reason(
                 case kind do
                   :web -> Fx.renew_web(c, web.ticket)
                   :ssh -> Fx.renew_ssh(c, ssh.ticket)
                 end
               )
    end

    assert {:ok, %{closed: true}} = Fx.close(c, :web, web.ticket)
    assert {:ok, %{closed: true}} = Fx.close(c, :ssh, ssh.ticket)

    assert Enum.sort(actions(WebStream.Version, [web.binding.session_id])) == [:close, :record]
    assert Enum.sort(actions(Session.Version, [ssh.binding.session_id])) == [:close, :record]
  end

  @type model :: %{
          revision: pos_integer(),
          visibility: :private | :public,
          port: pos_integer(),
          execution: boolean(),
          service: %{generation: pos_integer(), cert_acked: boolean()},
          service_token: String.t(),
          login_token: String.t() | nil,
          login_alive: boolean(),
          cookies: %{
            optional(non_neg_integer()) => %{
              value: String.t(),
              revoked: boolean(),
              generation: pos_integer(),
              login_dead: boolean()
            }
          },
          member_role: atom(),
          streams: [map()],
          route: nil | map(),
          publications: non_neg_integer(),
          publications_start: non_neg_integer(),
          sequence: non_neg_integer(),
          audit: map()
        }

  @spec initial(Fx.t()) :: model()
  defp initial(c) do
    zone = Application.fetch_env!(:marshall, :ingress_zone)

    publications_start =
      case Ledger.read!(Publication, zone: zone) do
        [] -> 0
        [%{revision: revision}] -> revision
      end

    %{
      revision: 2,
      visibility: :private,
      port: 8080,
      execution: true,
      service: %{generation: 1, cert_acked: false},
      service_token: c.service_token,
      login_token: nil,
      login_alive: true,
      cookies: %{},
      member_role: :web,
      streams: [],
      route: nil,
      publications: 0,
      publications_start: publications_start,
      sequence: 0,
      audit: %{
        web_record: 0,
        web_close: 0,
        ssh_record: 0,
        ssh_close: 0,
        route_versions: 0,
        endpoint_changes: 1,
        cred_record: 0,
        cred_revoke: 0
      }
    }
  end

  # ------------------------------------------------------------------ operators

  defp operations do
    frequency([
      {5, constant(:report)},
      {5, constant(:publish)},
      {2, constant(:acknowledge)},
      {5, gen_configure()},
      {7, gen_open_web()},
      {4, gen_open_ssh()},
      {6, gen_renew()},
      {4, gen_close()},
      {4, gen_expire()},
      {3, constant(:expire_route)},
      {4, gen_role()},
      {5, gen_withdraw()}
    ])
  end

  defp gen_configure,
    do:
      map(
        tuple({member_of([:private, :public]), member_of([8080, 8081])}),
        fn {visibility, port} -> {:configure, visibility, port} end
      )

  defp gen_open_web,
    do:
      map(
        tuple({member_of([:anonymous, :member]), member_of([0, 3000])}),
        fn {who, port} -> {:open_web, who, port} end
      )

  defp gen_open_ssh,
    do: map(member_of([:owner, :member]), &{:open_ssh, &1})

  defp gen_renew,
    do:
      map(
        tuple({member_of(@kinds), member_of([:live, :closed, :expired, :unknown])}),
        fn {kind, which} -> {:renew, kind, which} end
      )

  defp gen_close,
    do:
      map(
        tuple({member_of(@kinds), member_of([:live, :closed, :latest, :unknown])}),
        fn {kind, which} -> {:close, kind, which} end
      )

  defp gen_expire,
    do:
      map(
        tuple({member_of(@kinds), member_of([:live, :latest]), member_of([:past, :equal])}),
        fn {kind, which, boundary} -> {:expire_stream, kind, which, boundary} end
      )

  defp gen_role,
    do: map(member_of([:web, :viewer, :operator, :manager, :revoked]), &{:role, &1})

  defp gen_withdraw do
    map(
      member_of([
        :visibility,
        :signout,
        :credential_revoke,
        :rotation,
        :stop,
        :epoch
      ]),
      &{:withdraw, &1}
    )
  end

  # ------------------------------------------------------------- oracle rules

  defp web_member?(role), do: role in @web_roles
  defp write_member?(role), do: role in @write_roles

  defp cookie_error(cookie, m) do
    cond do
      cookie.revoked -> :authentication_required
      cookie.login_dead -> :authentication_required
      cookie.generation != m.service.generation -> :authentication_required
      true -> nil
    end
  end

  defp open_web_expected(m, who, port) do
    cond do
      not m.execution ->
        :unauthorized

      who == :anonymous or is_nil(m.cookies[port]) ->
        if m.visibility == :public and port == 0, do: :ok, else: :authentication_required

      cookie_error(m.cookies[port], m) != nil ->
        cookie_error(m.cookies[port], m)

      not web_member?(m.member_role) ->
        :forbidden

      true ->
        :ok
    end
  end

  defp open_ssh_expected(m, who) do
    cond do
      who == :member and not write_member?(m.member_role) -> :forbidden
      not m.execution -> :unauthorized
      true -> :ok
    end
  end

  defp renew_web_expected(m, stream) do
    cookie = if stream.who == :member, do: m.cookies[stream.app_port], else: nil

    cond do
      stream.service_generation != m.service.generation ->
        :unauthorized

      not m.execution ->
        :unauthorized

      stream.revision != m.revision ->
        :unauthorized

      stream.who == :member and is_nil(cookie) ->
        :authentication_required

      stream.who == :member and cookie_error(cookie, m) != nil ->
        cookie_error(cookie, m)

      stream.who == :member and not web_member?(m.member_role) ->
        :forbidden

      stream.who != :member and not (m.visibility == :public and stream.app_port == 0) ->
        :unauthorized

      stream.state == :closed ->
        :unauthorized

      stream.expired ->
        :unauthorized

      true ->
        :ok
    end
  end

  defp renew_ssh_expected(m, stream) do
    cond do
      stream.service_generation != m.service.generation -> :unauthorized
      stream.who == :member and not write_member?(m.member_role) -> :forbidden
      stream.state == :closed -> :unauthorized
      stream.expired -> :unauthorized
      not m.execution -> :unauthorized
      true -> :ok
    end
  end

  defp close_expected(m, stream) do
    if stream.service_generation == m.service.generation, do: :ok, else: :unauthorized
  end

  defp report_expected(m) do
    cond do
      not m.execution -> :unauthorized
      not m.service.cert_acked -> :unauthorized
      true -> :ok
    end
  end

  defp publish_membership?(m) do
    m.route != nil and not m.route.expired and m.execution and m.service.cert_acked and
      m.route.service_generation == m.service.generation
  end

  defp create_cookie_expected(m) do
    cond do
      not m.login_alive -> :unauthorized
      not m.execution -> :unauthorized
      not web_member?(m.member_role) -> :forbidden
      true -> :ok
    end
  end

  # ------------------------------------------------------------ step dispatch

  # The recorded gateway and browser callers always carry the current credential.
  defp current(c, m) do
    %{c | service_token: m.service_token, member_token: m.login_token || c.member_token}
  end

  defp apply_step(c, m, {:configure, visibility, port}) do
    changed? = visibility != m.visibility or port != m.port
    assert {:ok, endpoint} = Fx.configure_endpoint(c, port, visibility)

    if changed? do
      assert endpoint.policy_revision == m.revision + 1

      %{
        m
        | visibility: visibility,
          port: port,
          revision: m.revision + 1,
          audit: Map.update!(m.audit, :endpoint_changes, &(&1 + 1))
      }
    else
      assert endpoint.policy_revision == m.revision
      m
    end
  end

  defp apply_step(c, m, :report) do
    result = Fx.route_report(c)
    assert Fx.reason(result) == report_expected(m)

    case result do
      {:ok, reported} ->
        assert reported.label == c.label
        assert DateTime.diff(reported.expires_at, Ledger.now(), :millisecond) in 1..5100

        case m.route do
          nil ->
            assert reported.revision == 1

            %{
              m
              | route: %{
                  id: reported.id,
                  revision: 1,
                  expired: false,
                  service_generation: m.service.generation,
                  vm_generation: 1
                },
                audit: Map.update!(m.audit, :route_versions, &(&1 + 1))
            }

          route ->
            assert reported.id == route.id
            assert reported.revision == route.revision + 1
            replaced? = route.service_generation != m.service.generation

            %{
              m
              | route: %{
                  route
                  | revision: route.revision + 1,
                    expired: false,
                    service_generation: m.service.generation
                },
                audit:
                  if(replaced?,
                    do: Map.update!(m.audit, :route_versions, &(&1 + 1)),
                    else: m.audit
                  )
            }
        end

      {:error, _} ->
        m
    end
  end

  defp apply_step(c, m, :expire_route) do
    case m.route do
      nil ->
        m

      route ->
        Fx.backdate_route(route.id)
        assert {:error, _} = Fx.current_route(c)
        %{m | route: %{route | expired: true}}
    end
  end

  defp apply_step(c, m, :publish) do
    assert {:ok, snapshot} = Fx.publish(c)
    assert snapshot.revision == m.publications_start + m.publications + 1
    assert snapshot.proofs == []
    # Other generated runs share this zone transaction; assert only this
    # fixture's label membership.
    own = Enum.filter(snapshot.routes, &(&1.label == c.label))

    if publish_membership?(m) do
      assert [%{addresses: ["192.0.2.9"], ttl: ttl}] = own
      assert ttl in 1..5000
    else
      assert own == []
    end

    %{m | publications: m.publications + 1}
  end

  defp apply_step(c, m, :acknowledge) do
    assert {:ok, _} = Fx.acknowledge_certificate(c)
    put_in(m.service.cert_acked, true)
  end

  defp apply_step(c, m, {:open_web, who, port}) do
    m = ensure_cookie(c, m, who, port)
    cookie = if who == :anonymous or is_nil(m.cookies[port]), do: nil, else: m.cookies[port].value
    result = Fx.open_web(c, cookie, port)
    expected = open_web_expected(m, who, port)
    assert Fx.reason(result) == expected

    case result do
      {:ok, grant} ->
        assert grant.ttl in 1..30_000
        assert grant.binding.label == c.label
        assert grant.binding.service == :web

        [row] = Ledger.read!(WebStream, id: grant.binding.session_id)
        assert row.policy_revision == m.revision
        assert row.service_generation == m.service.generation

        stream = %{
          id: grant.binding.session_id,
          ticket: grant.ticket,
          kind: :web,
          who: who,
          app_port: port,
          state: :open,
          expired: false,
          revision: m.revision,
          service_generation: m.service.generation,
          binding: grant.binding
        }

        %{
          m
          | streams: m.streams ++ [stream],
            audit: Map.update!(m.audit, :web_record, &(&1 + 1))
        }

      {:error, _} ->
        if who == :member and m.cookies[port] != nil and
             cookie_error(m.cookies[port], m) == :authentication_required do
          # A dead browser identity is replaced by a fresh login, like the real
          # client cookie path.
          %{m | cookies: Map.delete(m.cookies, port)}
        else
          m
        end
    end
  end

  defp apply_step(c, m, {:open_ssh, who}) do
    result = Fx.open_ssh(c, who)
    assert Fx.reason(result) == open_ssh_expected(m, who)

    case result do
      {:ok, grant} ->
        assert grant.ttl == 30_000
        assert grant.binding.service == :ssh and grant.binding.port == 22

        stream = %{
          id: grant.binding.session_id,
          ticket: grant.ticket,
          kind: :ssh,
          who: who,
          credential: nil,
          app_port: 22,
          state: :open,
          expired: false,
          revision: m.revision,
          service_generation: m.service.generation,
          binding: grant.binding
        }

        %{
          m
          | streams: m.streams ++ [stream],
            audit: Map.update!(m.audit, :ssh_record, &(&1 + 1))
        }

      {:error, _} ->
        m
    end
  end

  defp apply_step(c, m, {:renew, kind, which}) do
    case pick(m.streams, kind, which) do
      :none ->
        m

      :unknown ->
        {ticket, _} = Token.issue(renew_purpose(kind))

        assert :unauthorized ==
                 Fx.reason(
                   case kind do
                     :web -> Fx.renew_web(c, ticket)
                     :ssh -> Fx.renew_ssh(c, ticket)
                   end
                 )

        m

      stream ->
        result =
          case kind do
            :web -> Fx.renew_web(c, stream.ticket)
            :ssh -> Fx.renew_ssh(c, stream.ticket)
          end

        expected = renew_expected(m, kind, stream)
        assert Fx.reason(result) == expected

        if expected == :ok do
          {:ok, renewed} = result
          assert renewed.binding == stream.binding
          assert renewed.ttl in 1..30_000
        end

        if kind == :web and stream.who == :member and
             is_nil(m.cookies[stream.app_port]) do
          m
        else
          m
        end
    end
  end

  defp apply_step(c, m, {:close, kind, which}) do
    case pick(m.streams, kind, which) do
      :none ->
        m

      :unknown ->
        {ticket, _} = Token.issue(renew_purpose(kind))

        assert :unauthorized ==
                 Fx.reason(
                   case kind do
                     :web -> Fx.close(c, :web, ticket)
                     :ssh -> Fx.close(c, :ssh, ticket)
                   end
                 )

        m

      stream ->
        result = Fx.close(c, kind, stream.ticket)
        expected = close_expected(m, stream)
        assert Fx.reason(result) == expected

        if expected == :ok do
          assert {:ok, %{closed: true}} = result
          key = if kind == :web, do: :web_close, else: :ssh_close
          # Closing an already-closed stream is idempotent and MUST write no new
          # durable version.
          audit =
            if stream.state == :open,
              do: Map.update!(m.audit, key, &(&1 + 1)),
              else: m.audit

          %{update_stream(m, stream, &%{&1 | state: :closed}) | audit: audit}
        else
          m
        end
    end
  end

  defp apply_step(_c, m, {:expire_stream, kind, which, boundary}) do
    case pick(m.streams, kind, which) do
      found when found in [:none, :unknown] ->
        m

      stream ->
        at = if boundary == :past, do: DateTime.add(Ledger.now(), -1), else: Ledger.now()
        Fx.expire_stream(stream.id, at, kind)
        update_stream(m, stream, &%{&1 | expired: true})
    end
  end

  defp apply_step(c, m, {:role, role}) do
    Fx.role(c, c.member, role)
    %{m | member_role: role}
  end

  defp apply_step(c, m, {:withdraw, :visibility}) do
    apply_step(c, m, {:configure, :private, m.port})
  end

  defp apply_step(c, m, {:withdraw, :signout}) do
    Fx.sign_out(c.member, current_token(c, m))

    refute match?({:ok, _, _}, Marshall.Accounts.Login.verify(current_token(c, m), c.member))

    %{
      m
      | cookies:
          Map.new(m.cookies, fn {port, cookie} -> {port, %{cookie | login_dead: true}} end),
        login_token: Fx.fresh_login(c)
    }
  end

  defp apply_step(_c, m, {:withdraw, :credential_revoke}) do
    # Revoke every live member browser credential, one durable version each.
    Enum.reduce(m.cookies, %{m | cookies: %{}}, fn
      {port, %{revoked: false, value: value} = cookie}, acc ->
        assert {:ok, _} = Fx.revoke_cookie(value)

        %{
          acc
          | cookies: Map.put(acc.cookies, port, %{cookie | revoked: true}),
            audit: Map.update!(acc.audit, :cred_revoke, &(&1 + 1))
        }

      {port, cookie}, acc ->
        put_in(acc, [:cookies, port], cookie)
    end)
  end

  defp apply_step(c, m, {:withdraw, :rotation}) do
    rotated = Fx.rotate(c)
    assert rotated.service.generation == m.service.generation + 1

    m_after = %{
      m
      | service_token: rotated.service_token,
        service: %{m.service | generation: rotated.service.generation, cert_acked: false}
    }

    # Rotation MUST immediately fence every pre-rotation stream presented with
    # the current gateway credential.
    Enum.each(m.streams, fn stream ->
      if stream.state == :open do
        renewed =
          case stream.kind do
            :web -> Fx.renew_web(%{c | service_token: m_after.service_token}, stream.ticket)
            :ssh -> Fx.renew_ssh(%{c | service_token: m_after.service_token}, stream.ticket)
          end

        assert Fx.reason(renewed) == :unauthorized
      end
    end)

    m_after
  end

  defp apply_step(c, m, {:withdraw, :stop}) do
    Fx.stop_intent(c)
    %{m | execution: false}
  end

  defp apply_step(c, m, {:withdraw, :epoch}) do
    Fx.epoch_bump(c)
    %{m | execution: false}
  end

  # ------------------------------------------------------------- model upkeep

  defp ensure_cookie(c, m, who, port) do
    if who == :member and is_nil(m.cookies[port]) do
      case Fx.cookie(c, current_token(c, m), port) do
        {:ok, value} ->
          assert create_cookie_expected(m) == :ok

          %{
            m
            | cookies:
                Map.put(m.cookies, port, %{
                  value: value,
                  revoked: false,
                  generation: m.service.generation,
                  login_dead: false
                }),
              audit: Map.update!(m.audit, :cred_record, &(&1 + 1))
          }

        {:error, error} ->
          assert Fx.reason({:error, error}) == create_cookie_expected(m),
                 "cookie exchange refusal class: #{inspect(Fx.reason({:error, error}))}"

          m
      end
    else
      m
    end
  end

  defp renew_expected(m, :web, stream), do: renew_web_expected(m, stream)
  defp renew_expected(m, :ssh, stream), do: renew_ssh_expected(m, stream)

  defp renew_purpose(:web), do: :web_stream
  defp renew_purpose(:ssh), do: :session

  defp update_stream(m, stream, fun) do
    %{m | streams: Enum.map(m.streams, &if(&1.id == stream.id, do: fun.(&1), else: &1))}
  end

  defp current_token(c, m), do: m.login_token || c.member_token

  defp pick(streams, kind, which) do
    pool = for stream <- streams, stream.kind == kind, do: stream

    case which do
      :unknown ->
        :unknown

      _ ->
        candidates =
          case which do
            :live -> for s <- pool, s.state == :open, not s.expired, do: s
            :closed -> for s <- pool, s.state == :closed, do: s
            :expired -> for s <- pool, s.expired and s.state == :open, do: s
            :latest -> pool
          end

        case candidates do
          [] -> :none
          list -> List.last(list)
        end
    end
  end

  # -------------------------------------------------------------- final audit

  defp audit(c, m) do
    # Durable rows match the model's stream lifecycle exactly.
    for stream <- m.streams do
      case stream.kind do
        :web ->
          [row] = Ledger.read!(WebStream, id: stream.id)
          assert is_nil(row.closed_at) == (stream.state == :open)
          assert row.policy_revision == stream.revision
          assert row.service_generation == stream.service_generation

          if stream.expired do
            assert DateTime.compare(row.expires_at, Ledger.now()) != :gt
          else
            assert DateTime.compare(row.expires_at, Ledger.now()) == :gt
          end

        :ssh ->
          [row] = Ledger.read!(Session, id: stream.id)
          assert is_nil(row.closed_at) == (stream.state == :open)
          assert DateTime.compare(row.expires_at, Ledger.now()) == :gt or stream.expired
      end
    end

    web_ids = for s <- m.streams, s.kind == :web, do: s.id
    ssh_ids = for s <- m.streams, s.kind == :ssh, do: s.id

    assert actions(WebStream.Version, web_ids) ==
             Enum.sort(
               List.duplicate(:record, m.audit.web_record) ++
                 List.duplicate(:close, m.audit.web_close)
             )

    assert actions(Session.Version, ssh_ids) ==
             Enum.sort(
               List.duplicate(:record, m.audit.ssh_record) ++
                 List.duplicate(:close, m.audit.ssh_close)
             )

    # Versions over this fixture never carry token material.
    for {module, ids} <- [{WebStream.Version, web_ids}, {Session.Version, ssh_ids}],
        version <- Enum.flat_map(ids, &Ledger.read!(module, version_source_id: &1)) do
      refute Map.has_key?(version.changes, "token_hash")
      refute Map.has_key?(version.changes, :token_hash)
    end

    for version <-
          Ledger.read!(WebCredential, vm_id: c.vm.id)
          |> Enum.flat_map(&Ledger.read!(WebCredential.Version, version_source_id: &1.id)) do
      refute Map.has_key?(version.changes, "token_hash")
      refute Map.has_key?(version.changes, :token_hash)
    end

    # Route durable history: record plus one replace per committed binding
    # change; refresh writes no version.
    route_versions =
      case m.route do
        nil -> []
        route -> actions(Route.Version, [route.id])
      end

    assert route_versions ==
             Enum.sort(
               List.duplicate(:record, 1) ++ List.duplicate(:replace, m.audit.route_versions - 1)
             )

    if m.route do
      assert [%{revision: revision}] = Ledger.read!(Route, id: m.route.id)
      assert revision == m.route.revision
    end

    assert [%{policy_revision: revision}] = Ledger.read!(Endpoint, id: c.endpoint.id)
    assert revision == m.revision

    assert actions(Endpoint.Version, [c.endpoint.id]) ==
             Enum.sort([:record | List.duplicate(:change_policy, m.audit.endpoint_changes)])

    credentials = Ledger.read!(WebCredential, vm_id: c.vm.id)
    assert length(credentials) == m.audit.cred_record
    assert Enum.count(credentials, &(&1.revoked_at != nil)) == m.audit.cred_revoke

    for {_port, cookie} <- m.cookies do
      {:ok, hash} = Token.digest(cookie.value, :web_cookie)
      [credential] = Ledger.read!(WebCredential, token_hash: hash)
      assert is_nil(credential.revoked_at) != cookie.revoked
    end

    zone = Application.fetch_env!(:marshall, :ingress_zone)

    case Ledger.read!(Publication, zone: zone) do
      [%{revision: revision}] -> assert revision == m.publications_start + m.publications
      [] -> assert m.publications_start + m.publications == 0
    end
  end

  defp actions(module, ids),
    do:
      ids
      |> Enum.flat_map(&Ledger.read!(module, version_source_id: &1))
      |> Enum.map(& &1.version_action_name)
      |> Enum.sort()
end
