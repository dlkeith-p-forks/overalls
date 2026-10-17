defmodule Marshall.Galileo do
  @moduledoc "Named edge integrations: configuration custody and request authorization."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Galileo.Credential
    resource Marshall.Galileo.Integration
    resource Marshall.Galileo.IntegrationHeader
    resource Marshall.Galileo.Attachment
    resource Marshall.Galileo.PeerToken

    resource Marshall.Galileo.PeerToken do
      define :issue_peer_token, action: :issue
    end

    resource Marshall.Galileo.Integration do
      define :list_integrations, action: :list_for_user
      define :configure_integration, action: :configure
      define :remove_integration, action: :remove
      define :attach_integration, action: :attach
      define :detach_integration, action: :detach
      define :show_integration, action: :show
      define :list_integrations_for_admin, action: :list_for_admin
    end
  end
end
