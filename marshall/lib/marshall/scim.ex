defmodule Marshall.Scim do
  @moduledoc "SCIM configuration and provisioning boundary."
  use Ash.Domain, otp_app: :marshall
  require Ash.Query

  resources do
    resource Marshall.Scim.Configuration
  end

  @spec enabled?() :: boolean()
  def enabled? do
    case Marshall.Scim.Configuration
         |> Ash.Query.filter(state == :enabled)
         |> Ash.read(actor: Marshall.Authorization.SystemActor.compute()) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
