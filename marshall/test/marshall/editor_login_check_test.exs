defmodule Marshall.EditorLoginCheckTest do
  use Marshall.DataCase, async: true

  alias Marshall.Accounts.Login
  alias Marshall.Editor.Authority

  # @cc [owner:ghuntley,label:verification;security] editor-login-real-lookup-failure
  # The actual database-backed login check MUST distinguish a definite removed
  # login from a caller whose unshared sandbox cannot answer the lookup. An
  # unavailable lookup MUST NOT be misclassified as stale authentication.
  test "current, revoked and unanswered stored logins retain different control classes" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {:ok, jti, expiry} = Login.verify(fixture.token, fixture.owner)
    assert Authority.check_login(jti, fixture.owner.id) == {:ok, expiry}

    parent = self()

    spawn(fn ->
      send(parent, {:unanswered, Authority.check_login(jti, fixture.owner.id)})
    end)

    assert_receive {:unanswered, {:error, :unavailable}}, 5_000

    Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM tokens WHERE jti = $1", [jti],
      log: false
    )

    assert Authority.check_login(jti, fixture.owner.id) == {:error, :authentication_required}
  end
end
