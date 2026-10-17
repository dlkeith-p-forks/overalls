defmodule Lilly.Transfer.ProbeRequest do
  @moduledoc "Closed connectivity probe grammar; no storage or execution authority."

  # @cc [owner:ghuntley,label:security] probe-request-is-never-shell-text
  # parse/1 MUST accept only the fixed verb and two canonical UUIDs separated by
  # single spaces, without normalization. Extra arguments and shell syntax fail.
  @spec parse(term()) ::
          {:ok, %{relocation_id: String.t(), challenge: String.t()}}
          | {:error, :export_permit_unconfirmed}
  def parse("lilly-probe-v3 " <> <<relocation::binary-size(36), " ", challenge::binary-size(36)>>) do
    if OverallsProtocol.uuid?(relocation) and OverallsProtocol.uuid?(challenge),
      do: {:ok, %{relocation_id: relocation, challenge: challenge}},
      else: {:error, :export_permit_unconfirmed}
  end

  def parse(_), do: {:error, :export_permit_unconfirmed}
end
