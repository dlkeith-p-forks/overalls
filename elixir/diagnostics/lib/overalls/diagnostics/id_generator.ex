defmodule Overalls.Diagnostics.IdGenerator do
  @moduledoc false

  @spec generate_trace_id() :: pos_integer()
  def generate_trace_id do
    case Process.get({Overalls.Diagnostics.Custody, :identity}) do
      nil -> :otel_id_generator.generate_trace_id()
      identity -> from_identity(identity, 128)
    end
  end

  @spec generate_span_id() :: pos_integer()
  def generate_span_id do
    case Process.get({Overalls.Diagnostics.Custody, :identity}) do
      nil -> :otel_id_generator.generate_span_id()
      identity -> from_identity(identity, 64)
    end
  end

  @doc false
  @spec from_identity(binary(), 64 | 128) :: pos_integer()
  def from_identity(identity, bits) when is_binary(identity) and bits in [64, 128] do
    <<value::unsigned-size(^bits), _::bitstring>> = :crypto.hash(:sha256, identity)
    max(1, value)
  end
end
