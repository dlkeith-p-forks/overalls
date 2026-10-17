defmodule Lilly.Transfer.ResumeToken do
  @moduledoc "Bounded native resume-token lineage checks; never transfer authority."
  alias Lilly.Host.Command

  # @cc [owner:ghuntley,label:security] resume-token-native-binding
  # validate/3 MUST require a bounded token and exact snapshot name/to GUID
  # binding through the pinned OpenZFS decoder, which rejects any nonzero from
  # GUID: every transfer is one full stream (ADR-0155), so a token naming any
  # parent snapshot MUST fail. Raw, saved, redacted, duplicate, unknown and wrongly
  # typed nvlist fields MUST fail. Only the fixed helper's exact success
  # response may pass. No token, utility output or exception may become a
  # diagnostic; callers independently retain current transfer authority.
  @spec validate(String.t(), map(), term()) :: :ok | {:error, :resume_token_unconfirmed}
  def validate(snapshot, %{to_guid: to}, token)
      when is_binary(snapshot) and byte_size(snapshot) in 1..255 and is_binary(to) and
             is_binary(token) and
             byte_size(token) in 1..8192 do
    with true <- OverallsProtocol.Storage.guid?(to),
         {:ok, "ok\n"} <- Command.run(:resume_token, [snapshot, to, token], 10_000),
         do: :ok,
         else: (_ -> {:error, :resume_token_unconfirmed})
  end

  def validate(_, _, _), do: {:error, :resume_token_unconfirmed}
end
