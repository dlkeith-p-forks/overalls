defmodule Marshall.Peach do
  use Ash.Domain, otp_app: :marshall

  resources do
    resource Marshall.Peach.Credential
    resource Marshall.Peach.Credential.Version
  end
end
