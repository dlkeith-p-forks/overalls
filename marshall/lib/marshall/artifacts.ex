defmodule Marshall.Artifacts do
  @moduledoc "Agent-published, versioned pages shared through Cedar roles."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Artifacts.Artifact
    resource Marshall.Artifacts.Version
    resource Marshall.Artifacts.VersionFile
    resource Marshall.Artifacts.Blob
    resource Marshall.Artifacts.Grant
    resource Marshall.Artifacts.AccessChange
    resource Marshall.Artifacts.StorageEntry
    resource Marshall.Artifacts.StorageUsage
    resource Marshall.Artifacts.ViewTicket
    resource Marshall.Artifacts.PublishRequest
    resource Marshall.Artifacts.AuditEvent
  end
end
