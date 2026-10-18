defmodule OverallsProtocol.AndroidDisplayRelay do
  @moduledoc "Closed, bounded preface for the Android display vsock relay."
  @maximum 4096
  @type mode :: :viewer | :controller
  @type message :: %{ticket: String.t(), generation: pos_integer(), mode: mode()}

  # @cc [owner:ghuntley,label:security;protocol] android-display-relay-preface
  # The relay preface MUST be closed, bounded and generation-bound. Unknown
  # fields, invalid modes, empty tickets and non-positive generations MUST be
  # rejected before a guest socket is opened.
  @spec maximum() :: pos_integer()
  def maximum, do: @maximum

  @spec encode(String.t(), pos_integer(), mode()) :: {:ok, binary()} | {:error, :invalid_message}
  def encode(ticket, generation, mode)
      when is_binary(ticket) and byte_size(ticket) in 1..2048 and
             is_integer(generation) and generation > 0 and mode in [:viewer, :controller] do
    encoded =
      JSON.encode!(%{
        "version" => 1,
        "ticket" => ticket,
        "generation" => generation,
        "mode" => Atom.to_string(mode)
      })

    if byte_size(encoded) <= @maximum, do: {:ok, encoded}, else: {:error, :invalid_message}
  end

  def encode(_, _, _), do: {:error, :invalid_message}

  @spec decode(binary()) :: {:ok, message()} | {:error, :invalid_message}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum do
    case JSON.decode(bytes) do
      {:ok, value} -> decode_map(value)
      _ -> {:error, :invalid_message}
    end
  end

  def decode(_), do: {:error, :invalid_message}

  defp decode_map(
         %{"version" => 1, "ticket" => ticket, "generation" => generation, "mode" => mode} = value
       )
       when map_size(value) == 4 and is_binary(ticket) and byte_size(ticket) in 1..2048 and
              is_integer(generation) and generation > 0 and mode in ["viewer", "controller"] do
    {:ok,
     %{
       ticket: ticket,
       generation: generation,
       mode: if(mode == "viewer", do: :viewer, else: :controller)
     }}
  end

  defp decode_map(_), do: {:error, :invalid_message}
end
