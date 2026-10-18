defmodule Marshall.Access do
  @moduledoc "VM membership and access decisions, backed by the shared database and Cedar."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Access.Grant do
      define :set_access, action: :set_access
      define :list_grants, action: :list_grants
      define :list_grants_for_admin, action: :list_for_admin
      define :revoke_grant_for_admin, action: :revoke_for_admin
    end

    resource Marshall.Access.Change

    resource Marshall.Access.Pin do
      define :pin_machine, action: :pin_machine
      define :unpin_machine, action: :unpin_machine
    end
  end
end
