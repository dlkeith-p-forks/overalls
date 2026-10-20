defmodule Marshall.Scim.Oidc.VerifiedClaims do
  @moduledoc """
  Claims from an ID token whose signature and binding checks have passed.

  Only `Marshall.Scim.Oidc.IdToken.verify/3` constructs this struct; sign-in
  accepts nothing else, so unverified query or form input cannot reach it.
  """

  @enforce_keys [:issuer, :subject, :expires_at]
  defstruct [:issuer, :subject, :expires_at]

  @type t :: %__MODULE__{
          issuer: String.t(),
          subject: String.t(),
          expires_at: integer()
        }
end
