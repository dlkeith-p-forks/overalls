defmodule Porsche.LocalizationCatalogTest do
  use ExUnit.Case, async: true

  @locales ~w(en zh-Hans hi es ar fr bn pt-BR pt-PT ru ur id de ja pcm mr te tr ta vi ko fil et fi sv)

  test "every supported locale covers the extracted terminal messages with matching placeholders" do
    sources = messages("default.pot")

    for locale <- @locales do
      translated = messages(Path.join([locale, "LC_MESSAGES", "default.po"]))
      assert Map.keys(translated) |> Enum.sort() == Map.keys(sources) |> Enum.sort()

      for {source, target} <- translated do
        refute String.trim(target) == ""
        assert placeholders(source) == placeholders(target)
      end
    end
  end

  test "shared help descriptions stay in the extraction inventory" do
    summaries = OverallsProtocol.SSHCommand.catalog() |> Enum.map(& &1.summary) |> Enum.sort()
    assert Enum.sort(Porsche.SSH.CommandMessages.sources()) == summaries
  end

  test "Japanese human errors are translated and JSON remains language neutral" do
    Gettext.put_locale(Porsche.Gettext, "ja")
    response = %{"version" => 1, "status" => "error", "error" => "invalid_command"}
    assert Porsche.SSH.Output.render(response, false) =~ "無効なコマンド"
    assert JSON.decode!(Porsche.SSH.Output.render(response, true)) == response
  end

  @spec messages(String.t()) :: %{String.t() => String.t()}
  defp messages(path) do
    :porsche
    |> :code.priv_dir()
    |> Path.join("gettext")
    |> Path.join(path)
    |> Expo.PO.parse_file!()
    |> Map.fetch!(:messages)
    |> Map.new(fn %Expo.Message.Singular{msgid: source, msgstr: target} ->
      {IO.iodata_to_binary(source), IO.iodata_to_binary(target)}
    end)
  end

  @spec placeholders(String.t()) :: [String.t()]
  defp placeholders(message),
    do: Regex.scan(~r/%\{[^}]+\}/, message) |> List.flatten() |> Enum.sort()
end
