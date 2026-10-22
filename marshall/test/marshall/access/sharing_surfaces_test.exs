defmodule Marshall.Access.SharingSurfacesTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  @moduletag capture_log: true

  alias Marshall.Compute.Ledger
  alias Marshall.SharingSurfacesFixture, as: Fixture

  @type role :: Fixture.role()

  @type model :: %{
          role: role(),
          terminal_shared: boolean(),
          terminal_attaches: non_neg_integer(),
          ssh_ticket: String.t() | nil,
          web_ticket: String.t() | nil,
          web_cookie: String.t() | nil,
          ssh_closed: [String.t()],
          web_closed: [String.t()],
          ssh_opened: [String.t()],
          web_opened: [String.t()]
        }

  # @cc [owner:ghuntley,label:verification;security] sharing-surfaces-one-history
  # One generated direct-role history MUST drive the real terminal
  # ticket/attach, SSH roster/open/renewal and web login/open/renewal surfaces
  # against the independent role/permission table in each step. Allowed
  # renewals MUST extend the same live lease; denied renewals MUST be closed
  # explicitly by the fixture and MUST never revive; fresh admission after
  # re-sharing MUST yield a new lease identity, never a recycled one.

  # Budget: all 100 generated cases (about 0.6-2 s each, mostly SQL, Ash policy and
  # Cedar authorization) took 238.7 s for this file on 2026-10-22 (180.2 s at
  # 6fad4d347, which raised test_cases to 100). Sized at about 2.5x that measurement.
  @tag timeout: 600_000
  @tag :hegel_case_sandbox
  property "one generated role history drives terminal, SSH and web entry and renewals",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    tail =
      draw(
        "tail",
        list_of(member_of([:web, :viewer, :operator, :manager, :revoked]),
          min_length: 2,
          max_length: 6
        )
      )

    c = Fixture.fixture()

    # Mandatory decisive transitions precede the generated tail: full
    # collapse to :revoked and re-admission are always exercised.
    roles = [:operator, :viewer, :manager, :web, :revoked, :operator] ++ tail

    initial = %{
      role: :revoked,
      terminal_shared: false,
      terminal_attaches: 0,
      ssh_ticket: nil,
      web_ticket: nil,
      web_cookie: nil,
      ssh_closed: [],
      web_closed: [],
      ssh_opened: [],
      web_opened: []
    }

    finished = Enum.reduce(roles, initial, &step(c, &2, &1))

    # A closed lease is terminal: no renewal or reuse revives it.
    for ticket <- finished.ssh_closed do
      assert {:error, _} = Fixture.renew_ssh(c, ticket)
    end

    for ticket <- finished.web_closed do
      assert {:error, _} = Fixture.renew_web(c, ticket)
    end

    # Every fresh admission created a distinct lease row identity.
    assert Enum.uniq(finished.ssh_opened) == finished.ssh_opened
    assert Enum.uniq(finished.web_opened) == finished.web_opened

    final = Fixture.expected(finished.role)

    assert length(Ledger.read!(Marshall.Access.Grant, vm_id: c.vm.id, user_id: c.member.id)) ==
             if(finished.role == :revoked, do: 0, else: 1)

    # The terminal grant requires read on the VM; once it exists it persists
    # across write/web-only roles, but tickets always recheck current read.
    terminal_grants =
      Ledger.read!(Marshall.Terminal.Grant, session_id: c.session.id, user_id: c.member.id)

    assert terminal_grants != [] == finished.terminal_shared

    events =
      Ledger.read!(Marshall.Terminal.Event, session_id: c.session.id)
      |> Enum.map(& &1.kind)

    assert Enum.count(events, &(&1 == :shared)) == if(finished.terminal_shared, do: 1, else: 0)
    assert Enum.count(events, &(&1 == :revoked)) == 0
    assert Enum.count(events, &(&1 == :attached)) == finished.terminal_attaches
    assert Enum.count(events, &(&1 == :detached)) == finished.terminal_attaches

    if final.read do
      assert finished.terminal_shared
    end

    # Every attachment was read-only: a shared member never dispatches input.
    effects = Fixture.effects(c)
    assert Enum.count(effects, &match?({:attach, _, _}, &1)) == finished.terminal_attaches
    assert Enum.count(effects, &match?({:gone, _}, &1)) == finished.terminal_attaches

    for {:attach, _, request} <- effects do
      assert request.mode == :ro
      assert request.cols == 0
      assert request.rows == 0
    end

    refute Enum.any?(effects, &match?({:input, _, _}, &1))
    refute Enum.any?(effects, &match?({:resize, _}, &1))
  end

  @spec step(Fixture.fixture(), model(), role()) :: model()
  defp step(c, model, role) do
    Fixture.fresh_host(c)
    assert {:ok, _} = Fixture.grant(c, role)
    model = %{model | role: role}
    expected = Fixture.expected(role)

    model
    |> terminal_step(c, expected)
    |> ssh_step(c, expected)
    |> web_step(c, expected)
  end

  @spec terminal_step(model(), Fixture.fixture(), Fixture.permissions()) :: model()
  defp terminal_step(model, c, expected) do
    # Sharing to a recipient without current VM read MUST be refused; a granted
    # viewing row persists across later role changes but every ticket rechecks.
    case Fixture.share_terminal(c) do
      :ok ->
        assert expected.read, "terminal sharing must require recipient VM read"
        model = %{model | terminal_shared: true}
        ticket_step(model, c, expected)

      {:error, :recipient_requires_vm_access} ->
        refute expected.read, "terminal sharing refused an eligible recipient"
        ticket_step(model, c, expected)

      other ->
        flunk("unexpected terminal sharing result: #{inspect(other)}")
    end
  end

  @spec ticket_step(model(), Fixture.fixture(), Fixture.permissions()) :: model()
  defp ticket_step(model, c, expected) do
    if model.terminal_shared and expected.read do
      {:ok, ticket} = Fixture.terminal_ticket(c)
      channel = Fixture.attach(c, ticket, 1_000 + model.terminal_attaches)
      assert channel > 0
      %{model | terminal_attaches: model.terminal_attaches + 1}
    else
      assert {:error, :forbidden} = Fixture.terminal_ticket(c)
      model
    end
  end

  @spec ssh_step(model(), Fixture.fixture(), Fixture.permissions()) :: model()
  defp ssh_step(model, c, expected) do
    # The Audi roster lists exactly the current writers; a member enters or
    # leaves it purely from the model role.
    {:ok, roster} = Fixture.roster(c)
    usernames = Enum.map(roster.accounts, & &1.username)
    assert Enum.member?(usernames, c.member_name) == expected.write
    assert length(usernames) == if(expected.write, do: 2, else: 1)

    model =
      case model.ssh_ticket do
        nil ->
          model

        ticket ->
          case {expected.write, Fixture.renew_ssh(c, ticket)} do
            {true, {:ok, renewed}} ->
              assert renewed.binding.session_id
              assert renewed.ttl > 0 and renewed.ttl <= 30_000
              model

            {false, {:error, _}} ->
              assert {:ok, %{closed: true}} = Fixture.close_ssh(c, ticket)
              %{model | ssh_ticket: nil, ssh_closed: [ticket | model.ssh_closed]}

            {_, other} ->
              flunk("SSH renewal must follow the model: #{inspect(other)}")
          end
      end

    case model.ssh_ticket do
      nil ->
        case {expected.write, Fixture.open_ssh(c)} do
          {true, {:ok, grant}} ->
            assert grant.binding.service == :ssh
            assert grant.binding.port == 22

            %{
              model
              | ssh_ticket: grant.ticket,
                ssh_opened: [grant.binding.session_id | model.ssh_opened]
            }

          {false, {:error, _}} ->
            model

          {_, other} ->
            flunk("SSH admission must follow the model: #{inspect(other)}")
        end

      _ticket ->
        model
    end
  end

  @spec web_step(model(), Fixture.fixture(), Fixture.permissions()) :: model()
  defp web_step(model, c, expected) do
    model =
      case model.web_ticket do
        nil ->
          model

        ticket ->
          case {expected.web, Fixture.renew_web(c, ticket)} do
            {true, {:ok, renewed}} ->
              assert renewed.binding.session_id
              assert renewed.ttl > 0 and renewed.ttl <= 30_000
              model

            {false, {:error, _}} ->
              assert {:ok, %{closed: true}} = Fixture.close_web(c, ticket)
              %{model | web_ticket: nil, web_closed: [ticket | model.web_closed]}

            {_, other} ->
              flunk("web renewal must follow the model: #{inspect(other)}")
          end
      end

    # The real login exchange rechecks current web permission every time.
    case {expected.web, Fixture.approve_web(c)} do
      {true, {:ok, cookie}} ->
        %{model | web_cookie: cookie}

      {false, {:error, _}} ->
        # A cookie minted while web access was allowed MUST NOT reopen a stream
        # after withdrawal; it is inert until a fresh login exchange succeeds.
        if model.web_cookie,
          do: assert({:error, _} = Fixture.open_web(c, model.web_cookie))

        %{model | web_cookie: nil}

      {_, other} ->
        flunk("web login exchange must follow the model: #{inspect(other)}")
    end
    |> then(fn model ->
      case {model.web_ticket, model.web_cookie} do
        {nil, cookie} when is_binary(cookie) ->
          # Fresh admission after re-sharing creates a new lease row identity.
          {:ok, grant} = Fixture.open_web(c, cookie)
          assert grant.binding.service == :web
          assert grant.binding.port == 8080
          assert grant.ttl > 0 and grant.ttl <= 30_000

          %{
            model
            | web_ticket: grant.ticket,
              web_opened: [grant.binding.session_id | model.web_opened]
          }

        _ ->
          model
      end
    end)
  end
end
