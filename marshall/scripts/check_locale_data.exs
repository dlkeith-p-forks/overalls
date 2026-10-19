defmodule Marshall.LocaleDataCheck do
  @moduledoc "Checks the vendored CLDR data against the pinned Localize package."
  @locales ~w(en zh hi es ar fr bn pt pt-PT ru ur id de ja pcm mr te tr ta vi ko fil et fi sv ar-EG sw ha und)a

  @spec run() :: :ok
  def run do
    root = Path.expand("..", __DIR__)
    manifest = Path.join(root, "deps/localize/priv/localize/locale_hashes.etf")
    hashes = manifest |> File.read!() |> :erlang.binary_to_term()

    for locale <- @locales do
      path = Path.join(root, "priv/localize/locales/#{locale}.etf")
      bytes = File.read!(path)
      expected = Map.fetch!(hashes, locale)

      unless :crypto.hash(:sha256, bytes) == expected,
        do:
          raise(
            "CLDR integrity failure for #{locale}; regenerate using the pinned Localize package"
          )

      data = :erlang.binary_to_term(bytes)

      unless match?(%{layout: %{character_order: order}} when order in [:ltr, :rtl], data),
        do: raise("CLDR layout missing for #{locale}")
    end

    IO.puts(
      "Verified #{length(@locales)} bundled CLDR datasets against the pinned Localize manifest"
    )

    :ok
  end
end

Marshall.LocaleDataCheck.run()
