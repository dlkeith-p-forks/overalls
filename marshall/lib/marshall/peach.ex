defmodule Marshall.Peach do
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Peach.Credential
    resource Marshall.Peach.Credential.Version
  end
end
