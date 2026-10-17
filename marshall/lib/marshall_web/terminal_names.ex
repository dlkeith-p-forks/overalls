defmodule MarshallWeb.TerminalNames do
  @moduledoc """
  Deterministic, memorable display names for terminal sessions.

  A session is labelled `adjective-noun` derived from a hash of its id, so
  every browser shows the same name for the same session without storing
  anything. A browser-local name chosen by the user replaces it; the guest's
  own title stays in the detail line.
  """

  @adjectives ~w(amber brave calm clever cosy dusty eager fuzzy gentle golden
    happy humble jolly keen lazy lively lucky mellow merry nimble plucky quiet
    rosy sleepy snug sunny swift tidy velvet warm witty zesty)
  @nouns ~w(tabby calico manx sphynx bengal siamese persian ragdoll bobtail
    birman burmese ocicat toyger korat somali savannah abyssinian balinese
    chartreux cymric javanese khaomanee laperm munchkin nebelung peterbald
    singapura snowshoe sokoke tonkinese turkish york)

  @doc "Returns the generated `adjective-noun` label for a session id."
  @spec display_name(String.t()) :: String.t()
  def display_name(session_id) when is_binary(session_id) do
    <<a::16, n::16, _::binary>> = :crypto.hash(:sha256, session_id)

    Enum.at(@adjectives, rem(a, length(@adjectives))) <>
      "-" <> Enum.at(@nouns, rem(n, length(@nouns)))
  end
end
