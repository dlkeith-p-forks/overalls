defmodule Marshall.Editor do
  @moduledoc "Browser editor authority, independent from ordinary web endpoint policy."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Editor.Login do
      define :launch, action: :launch
      define :begin_editor_login, action: :begin_login
      define :authorize_editor_login, action: :authorize_login
      define :exchange_editor_login, action: :exchange_login
    end

    resource Marshall.Editor.Credential

    resource Marshall.Editor.Lease do
      define :open_editor, action: :open_editor
      define :renew_editor, action: :renew_editor
      define :close_editor, action: :close_editor
      define :audit, action: :audit
    end
  end
end
