defmodule Marshall.Inference do
  @moduledoc "Durable private inference admission and owner-attributed usage."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Inference.Credential
    resource Marshall.Inference.Daily

    resource Marshall.Inference.Request do
      define :list_usage, action: :list_for_user
      define :list_usage_for_admin, action: :list_for_admin
    end
  end
end
