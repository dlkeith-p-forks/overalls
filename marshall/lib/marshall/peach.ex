defmodule Marshall.Peach do
  use Ash.Domain, otp_app: :marshall

  resources do
    resource Marshall.Peach.Credential
  end
end
