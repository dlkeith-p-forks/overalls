defmodule Marshall.Authorization.SystemActor do
  @moduledoc """
  A trusted in-process actor for the compute coordinator and its durable jobs.

  Never construct this actor from HTTP parameters, a socket payload or a claimed
  role. External provisioner identities must be authenticated separately.
  """
  @enforce_keys [:purpose]
  defstruct [:purpose]
  @type t :: %__MODULE__{purpose: :compute}

  @spec compute() :: t()
  def compute, do: %__MODULE__{purpose: :compute}
end
