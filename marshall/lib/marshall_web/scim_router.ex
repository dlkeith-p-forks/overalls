defmodule MarshallWeb.ScimRouter do
  use AshScim.Router,
    domains: [Marshall.Accounts],
    auth: {Marshall.Scim.Auth, []},
    base_url: "/scim/v2"
end
