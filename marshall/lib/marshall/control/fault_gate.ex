defmodule Marshall.Control.FaultGate do
  @moduledoc """
  Test-only transport fault gate for the control socket (ADR-0142).

  Only native tests configure a gate file. A request whose op is listed in it
  is answered `temporarily_unavailable` before any domain function runs: the
  socket equivalent of a proxy rejecting one HTTPS path. Production releases
  configure no file, so the gate never matches.
  """

  # @cc [owner:ghuntley,label:verification;security] control-fault-gate-transport-only
  # The gate MUST only refuse listed ops with the fixed unavailable answer
  # before dispatch. It MUST NOT manufacture results, touch the database or
  # change authority, and it MUST be inert without an operator-supplied file.
  @spec blocked?(String.t()) :: boolean()
  def blocked?(op) when is_binary(op) do
    with path when is_binary(path) <- Application.get_env(:marshall, :control_fault_gate_file),
         {:ok, text} <- File.read(path) do
      op in String.split(text, "\n", trim: true)
    else
      _ -> false
    end
  end
end
