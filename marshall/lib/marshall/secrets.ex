defmodule Marshall.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Marshall.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:marshall, :token_signing_secret)
  end
end
