defmodule Marshall.Accounts.LoginCheckTest do
  use Marshall.DataCase, async: true

  alias Marshall.Accounts.Login

  # @cc [owner:ghuntley,label:verification;security] login-check-refused-vs-unavailable
  # A current login MUST be accepted, a removed one MUST be :refused, and a
  # lookup that cannot reach the database MUST be :unavailable, never accepted.
  test "a current login is accepted, a removed one refused, an unreachable lookup unavailable" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {:ok, jti, _expiry} = Login.verify(fixture.token, fixture.owner)

    assert {:ok, _} = Login.check(jti, fixture.owner.id)
    assert {:ok, _} = Login.token_check(jti, fixture.owner.id)

    # An async (unshared) sandbox gives a bare spawned process no database.
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:unreached, Login.check(jti, fixture.owner.id), Login.present(jti, fixture.owner.id)}
      )
    end)

    assert_receive {:unreached, :unavailable, :error}, 5_000

    Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM tokens WHERE jti = $1", [jti],
      log: false
    )

    assert Login.check(jti, fixture.owner.id) == :refused
    assert Login.token_check(jti, fixture.owner.id) == :refused
    assert Login.present(jti, fixture.owner.id) == :error
  end
end
