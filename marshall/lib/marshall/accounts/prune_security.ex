defmodule Marshall.Accounts.PruneSecurity do
  @moduledoc "Bounded retention for consumed challenges and expired stored-login verification."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_, _, _) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "DELETE FROM account_passkey_challenges WHERE id IN (SELECT id FROM account_passkey_challenges WHERE expires_at <= clock_timestamp() ORDER BY expires_at LIMIT 1000)",
      [],
      log: false
    )

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "DELETE FROM account_verifications WHERE id IN (SELECT v.id FROM account_verifications v LEFT JOIN tokens t ON t.jti=v.id AND t.purpose='user' AND t.expires_at > clock_timestamp() WHERE t.jti IS NULL LIMIT 1000)",
      [],
      log: false
    )

    {:ok, :pruned}
  end
end
