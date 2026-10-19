defmodule Susan.Audit do
  @moduledoc """
  Susan's append-only, hash-chained audit trail (ADR-0224), stored in Susan's
  own database and retained for 90 days.
  """
  use Ash.Domain, otp_app: :susan

  resources do
    resource Susan.Audit.AuditEntry
  end
end
