defmodule Lilly.Host.Lease do
  @moduledoc """
  A lease held through lilly-hostd on one lock directory (ADR-0176 decision 4).

  `monitor` watches the BEAM's hostd session process from the holder: a lost
  session arrives at the holder as `{:DOWN, monitor, :process, _, _}`, and
  hostd refuses every command under the lost lease.
  """

  @enforce_keys [:id, :session, :monitor]
  defstruct [:id, :session, :monitor, :directory]

  @type t :: %__MODULE__{
          id: pos_integer(),
          session: pid(),
          monitor: reference(),
          directory: Path.t() | nil
        }
end
