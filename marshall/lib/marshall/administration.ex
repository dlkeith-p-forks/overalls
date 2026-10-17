defmodule Marshall.Administration do
  @moduledoc "Explicit administrative projections and audited operations."
  use Ash.Domain, otp_app: :marshall

  resources do
    resource Marshall.Administration.JobSnapshot do
      define :jobs, action: :list_for_admin
      define :job, action: :get_for_admin
      define :retry_job, action: :retry_for_admin
    end

    resource Marshall.Administration.JobEvent
    resource Marshall.Administration.AuditEvent
  end
end
