defmodule Marshall.SSH do
  @moduledoc "Account SSH identity and management authority, persisted through Ash."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.SSH.HostCertificate do
      define :host_certificate, action: :request
    end

    resource Marshall.SSH.GuestLogin

    resource Marshall.SSH.Request do
      define :run_execute, action: :execute
    end

    resource Marshall.SSH.Gateway do
      define :gateway_ready, action: :ready
      define :configure_gateway, action: :configure
      define :ensure_gateway, action: :ensure
      define :disable_gateway, action: :disable
    end

    resource Marshall.SSH.Session do
      define :open_session, action: :open_session
      define :session_status, action: :session_status
      define :close_session, action: :close_session
      define :list_sessions_for_admin, action: :list_for_admin
      define :revoke_session_for_admin, action: :revoke_for_admin
    end

    resource Marshall.SSH.Approval do
      define :inspect_approval, action: :inspect_approval
      define :approve_key, action: :approve_key
    end

    resource Marshall.SSH.Key do
      define :list_keys, action: :list_for_user
      define :add_key, action: :add_for_user
      define :rename_key, action: :rename_for_user
      define :remove_key, action: :remove_for_user
      define :list_keys_for_admin, action: :list_for_admin
      define :revoke_key_for_admin, action: :revoke_for_admin
    end
  end

  @spec execute(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(arguments, options \\ []),
    do:
      Marshall.Compute.Ledger.commit_scope(fn ->
        run_execute(arguments, options)
      end)
end
