defmodule Marshall.Enrico do
  @moduledoc "Registration and durable refresh state for public GitHub mirrors."
  use Ash.Domain, otp_app: :marshall

  resources do
    resource Marshall.Enrico.Repository
    resource Marshall.Enrico.AuditEvent
  end
end
