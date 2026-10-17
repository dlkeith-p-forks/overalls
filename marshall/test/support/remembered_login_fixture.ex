defmodule Marshall.RememberedLoginFixture do
  @moduledoc "Committed PostgreSQL gates for login-issuance/revocation races."
  alias Marshall.Accounts.User

  # @cc [owner:ghuntley,label:verification] remembered-race-real-locks
  # Gates MUST pause real Ash exchange/sign-in/revocation while its account
  # lock is held by production code. The fixture MUST NOT acquire the account
  # lock or create login tokens in place of the tested actions.
  @spec exchange(String.t(), integer()) :: {:ok, User.t() | nil} | {:error, term()}
  def exchange(token, gate) do
    User
    |> Ash.Query.for_read(:sign_in_with_remember_me, %{token: token},
      context: %{
        private: %{ash_authentication?: true},
        strategy_name: AshAuthentication.Info.strategy!(User, :remember_me)
      }
    )
    |> Ash.Query.before_action(fn query ->
      wait_gate(gate)
      query
    end)
    |> Ash.read_one()
  end

  @spec revoke(User.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def revoke(admin, id) do
    User
    |> Ash.ActionInput.for_action(:revoke_sessions_for_admin, %{user_id: id}, actor: admin)
    |> Ash.run_action()
  end

  # Runs the real magic-link sign-in create action exactly as the authentication
  # strategy does, with two advisory gates: the first pauses inside the sign-in
  # transaction after every production before_action hook (production locks and
  # single-use consumption already hold), the second pauses after commit but
  # before the upstream post-commit session token store, opening the issuance
  # window between the identity commit and the session credential insert.
  @spec sign_in(String.t(), {integer(), integer()}) :: {:ok, User.t()} | {:error, term()}
  def sign_in(token, {gate_before, gate_after}) do
    User
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{token: token, remember_me: true})
    |> Ash.Changeset.before_action(fn changeset ->
      wait_gate(gate_before)
      changeset
    end)
    |> Ash.Changeset.after_transaction(
      fn _changeset, result ->
        wait_gate(gate_after)
        result
      end,
      prepend?: true
    )
    |> Ash.create()
  end

  @spec reset_mfa(User.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def reset_mfa(%User{} = admin, id) do
    User
    |> Ash.ActionInput.for_action(:reset_mfa, %{user_id: id}, actor: admin)
    |> Ash.run_action()
  end

  @spec retire(User.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def retire(%User{} = admin, id, confirmation) do
    User
    |> Ash.ActionInput.for_action(:delete_user, %{user_id: id, confirmation: confirmation},
      actor: admin
    )
    |> Ash.run_action()
  end

  # Runs the real controller sign-out for a browser holding only the supplied
  # remember cookie, exactly as the router pipeline does. The production
  # transaction locks the credential accounts and revokes them; any pause comes
  # from the revoke trigger gate.
  @spec sign_out(String.t(), String.t()) :: Plug.Conn.t()
  def sign_out(cookie_name, cookie) do
    "DELETE"
    |> Plug.Test.conn("/sign-out")
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash([])
    |> Plug.Conn.put_req_header("cookie", "#{cookie_name}=#{cookie}")
    |> MarshallWeb.AuthController.sign_out(%{})
  end

  # A target-only trigger stops inside the production UPDATE, without supplying
  # its account lock. Removing that production lock lets exchange overtake it.
  @spec install_revoke_gate(String.t(), pos_integer()) :: :ok
  def install_revoke_gate(id, gate) do
    name = trigger_name(id)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      """
      CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.subject = TG_ARGV[0] AND NEW.purpose = 'revocation' THEN
          PERFORM pg_advisory_xact_lock(TG_ARGV[1]::bigint);
        END IF;
        RETURN NEW;
      END;
      $$
      """,
      [],
      log: false
    )

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      """
      CREATE TRIGGER #{name} BEFORE UPDATE OF purpose ON tokens
      FOR EACH ROW EXECUTE FUNCTION #{name}('user?id=#{Ecto.UUID.cast!(id)}', '#{gate}')
      """,
      [],
      log: false
    )

    :ok
  end

  @spec remove_revoke_gate(String.t()) :: :ok
  def remove_revoke_gate(id) do
    name = trigger_name(id)

    Ecto.Adapters.SQL.query!(Marshall.Repo, "DROP TRIGGER IF EXISTS #{name} ON tokens", [],
      log: false
    )

    Ecto.Adapters.SQL.query!(Marshall.Repo, "DROP FUNCTION IF EXISTS #{name}()", [], log: false)
    :ok
  end

  @spec trigger_name(String.t()) :: String.t()
  defp trigger_name(id), do: "remember_gate_" <> String.replace(Ecto.UUID.cast!(id), "-", "_")

  @spec wait_gate(integer()) :: :ok
  defp wait_gate(0), do: :ok

  defp wait_gate(gate) do
    Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT pg_advisory_xact_lock($1)", [gate],
      log: false
    )

    :ok
  end
end
