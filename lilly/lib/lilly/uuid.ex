defmodule Lilly.UUID do
  @moduledoc false
  # @cc [owner:ghuntley,label:protocol] uuid-random-v4-wire-identity
  # generate/0 MUST return a lowercase canonical RFC-4122 variant UUID with version 4 bits from
  # cryptographically random input so local session, operation and incarnation identities satisfy
  # the shared wire validator.
  @spec generate() :: OverallsProtocol.uuid()
  def generate do
    <<a::32, b::16, _::4, c::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c::12, 2::2, d::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end
end
