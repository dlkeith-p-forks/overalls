defmodule MarshallWeb.ControlRoomHistoryTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  import Phoenix.LiveViewTest

  alias Marshall.Accounts.{AdminEvent, Security, User, Verification}
  alias Marshall.Compute.Ledger
  alias Marshall.PasskeyFixture, as: Fixture

  @typep authority :: %{live: boolean(), administrator: boolean(), elevated: boolean()}
  @typep event ::
           :promote | :demote | :verify | :lock | :expire_elevation | :revoke | :expire_login

  # @cc [owner:ghuntley,label:verification] control-room-history-oracle
  # Generated histories MUST exercise persisted roles and stored sessions against
  # actual domain actions and mounted browser event guards. Rejected mutations
  # MUST preserve the target role and audit count, even with a stale forged actor.

  # Enrollment and initial verification consume two of the ten retained challenge
  # slots; eight transitions keep every generated verify within that separate limit.
  @tag :hegel
  test "current role and login histories govern Control room reads and audited writes", %{
    conn: conn
  } do
    check all(
            administrator <- boolean(),
            forged_role <- boolean(),
            events <-
              list_of(
                member_of([
                  :promote,
                  :demote,
                  :verify,
                  :lock,
                  :expire_elevation,
                  :revoke,
                  :expire_login
                ]),
                min_length: 1,
                max_length: 8
              ),
            test_cases: 25
          ) do
      assert_history(conn, administrator, forged_role, events)
    end
  end

  test "a mounted actor gains, loses and regains authority before terminal session invalidation",
       %{conn: conn} do
    for {administrator, events} <- [
          {true, [:demote, :promote, :lock, :verify, :expire_elevation, :verify, :revoke]},
          {false, [:promote, :demote, :verify, :promote, :expire_login, :verify]}
        ] do
      assert %{live: false} = assert_history(conn, administrator, not administrator, events)
    end
  end

  @spec assert_history(Plug.Conn.t(), boolean(), boolean(), [event()]) :: authority()
  defp assert_history(conn, administrator, forged_role, events) do
    actor = Fixture.elevate(Fixture.user(administrator))
    target = Fixture.user()
    conn = signed_in(conn, actor)
    stale_actor = %{actor | administrator: forged_role}

    Enum.reduce(events, %{live: true, administrator: administrator, elevated: true}, fn event,
                                                                                        before ->
      mounted = if before.live, do: live(conn, ~p"/admin/users"), else: nil
      after_event = transition(event, actor, before)
      allowed = after_event.live and after_event.administrator and after_event.elevated
      target_before = Security.current(target.id).administrator
      audit_before = length(Ledger.read!(AdminEvent))

      if mounted do
        {:ok, view, _} = mounted
        payload = %{"id" => target.id, "enabled" => to_string(not target_before)}

        cond do
          not after_event.live ->
            render_click(view, "set-role", payload)
            assert_redirect(view, ~p"/sign-in")

          after_event.administrator and not after_event.elevated ->
            render_click(view, "set-role", payload)
            assert_push_event(view, "admin-step-up-open", %{nonce: nonce})
            assert OverallsProtocol.uuid?(nonce)

          true ->
            render_click(view, "set-role", payload)
        end
      end

      assert Security.current(target.id).administrator ==
               if(allowed, do: not target_before, else: target_before)

      assert length(Ledger.read!(AdminEvent)) == audit_before + if(allowed, do: 1, else: 0)

      result =
        User
        |> Ash.ActionInput.for_action(:list_admin_users, %{}, actor: stale_actor)
        |> Ash.run_action()

      assert match?({:ok, _}, result) == after_event.live

      assert get(conn, ~p"/admin/usage/export").status ==
               if(after_event.live, do: 200, else: 404)

      current_target = Security.current(target.id).administrator
      audit_before = length(Ledger.read!(AdminEvent))

      result =
        User
        |> Ash.ActionInput.for_action(
          :set_administrator,
          %{user_id: target.id, administrator: not current_target},
          actor: stale_actor
        )
        |> Ash.run_action()

      assert match?({:ok, _}, result) == allowed

      assert Security.current(target.id).administrator ==
               if(allowed, do: not current_target, else: current_target)

      assert length(Ledger.read!(AdminEvent)) == audit_before + if(allowed, do: 1, else: 0)
      after_event
    end)
  end

  @spec transition(event(), User.t(), authority()) :: authority()
  defp transition(event, actor, state) when event in [:promote, :demote] do
    administrator = event == :promote

    Ledger.update!(Security.current(actor.id), :assign_administrator, %{
      administrator: administrator
    })

    %{state | administrator: administrator}
  end

  defp transition(:verify, actor, state) do
    result =
      case Fixture.action(actor, :begin_verify) do
        {:ok, challenge} ->
          Fixture.action(
            actor,
            :finish_verify,
            Fixture.assertion(challenge, actor.__metadata__.test_authenticator)
          )

        error ->
          error
      end

    assert match?({:ok, %{verified: true}}, result) == state.live
    %{state | elevated: state.live}
  end

  defp transition(:lock, actor, state) do
    Fixture.action(actor, :lock)
    %{state | elevated: false}
  end

  defp transition(:expire_elevation, actor, state) do
    [proof] = Ledger.read!(Verification, id: Security.jti(actor))
    Ledger.update!(proof, :verify, %{elevated_until: Ledger.now()})
    %{state | elevated: false}
  end

  defp transition(:revoke, actor, state) do
    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        actor.__metadata__.token
      )

    %{state | live: false, elevated: false}
  end

  defp transition(:expire_login, actor, state) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE tokens SET expires_at = clock_timestamp() - interval '1 second' WHERE jti = $1",
      [Security.jti(actor)],
      log: false
    )

    %{state | live: false, elevated: false}
  end

  @spec signed_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  defp signed_in(conn, actor) do
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(actor)
  end
end
