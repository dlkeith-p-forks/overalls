defmodule Marshall.Galileo.IssuedCredential do
  @moduledoc "One-time deployment result. Secret delivery remains outside administrative browser views."
  @derive {Inspect, except: [:secret]}
  @enforce_keys [:id, :host_id, :secret, :expires_at]
  defstruct [:id, :host_id, :secret, :expires_at]

  @type t :: %__MODULE__{
          id: String.t(),
          host_id: String.t(),
          secret: String.t(),
          expires_at: DateTime.t()
        }
end
