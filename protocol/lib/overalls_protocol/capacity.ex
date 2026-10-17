defmodule OverallsProtocol.Capacity do
  @moduledoc "Versioned physical headroom and generation-bound sampling coverage."
  @max 9_223_372_036_854_775_807

  # @cc [owner:ghuntley,label:capacity] capacity-unknown-and-bounded
  # Missing usage MUST remain unknown. Known headroom requires a complete bounded
  # interval and at most 4096 unique placement proofs with exact epoch/generation
  # and outcome identities. Invalid values MUST NOT become zero usage.
  @spec valid?(term()) :: boolean()
  def valid?(nil), do: true

  def valid?(
        %{
          "version" => 1,
          "cpu_headroom_millicores" => cpu,
          "memory_headroom_bytes" => memory,
          "interval_us" => interval,
          "covered" => covered
        } = value
      )
      when map_size(value) == 5 do
    integer?(cpu, 0, @max) and integer?(memory, 0, @max) and
      integer?(interval, 1, 5_000_000) and is_map(covered) and map_size(covered) <= 4096 and
      Enum.all?(covered, fn {id, proof} -> OverallsProtocol.uuid?(id) and proof?(proof) end)
  end

  def valid?(_), do: false

  @spec proof?(term()) :: boolean()
  def proof?(
        %{
          "execution_epoch" => epoch,
          "generation" => generation,
          "outcome_id" => outcome,
          "compute" => compute,
          "disk" => disk
        } = proof
      )
      when map_size(proof) == 5,
      do:
        integer?(epoch, 1, @max) and integer?(generation, 1, @max) and
          OverallsProtocol.uuid?(outcome) and is_boolean(compute) and is_boolean(disk)

  def proof?(_), do: false
  defp integer?(n, low, high), do: is_integer(n) and n >= low and n <= high
end
