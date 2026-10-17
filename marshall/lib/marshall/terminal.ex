defmodule Marshall.Terminal do
  @moduledoc "Durable terminal session registry and its audit events."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Terminal.Grant
    resource Marshall.Terminal.Location
    resource Marshall.Terminal.Opening

    resource Marshall.Terminal.Session do
      define :list_for_vm, action: :list_for_vm, args: [:vm_id]
    end

    resource Marshall.Terminal.Event do
      define :record, action: :record
    end

    resource Marshall.Terminal.Ticket do
      define :create_ticket, action: :create
    end
  end
end
