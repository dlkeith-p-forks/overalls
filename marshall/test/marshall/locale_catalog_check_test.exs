defmodule Marshall.LocaleCatalogCheckTest do
  use ExUnit.Case, async: true

  alias Expo.Message.{Plural, Singular}

  @checker Path.expand("../../scripts/check_locale_catalogs.exs", __DIR__)
  @review Path.expand("../../scripts/locale_catalog_review.exs", __DIR__)
  @type fixture :: %{root: Path.t(), checker: Path.t(), support: Path.t()}
  @type review_record :: %{
          String.t() => String.t() | non_neg_integer() | nil
        }

  setup do
    root = Path.join(System.tmp_dir!(), "locale-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "scripts"))
    on_exit(fn -> File.rm_rf!(root) end)
    checker = Path.join(root, "scripts/check_locale_catalogs.exs")
    support = Path.join(root, "support.exs")
    File.cp!(@checker, checker)
    File.cp!(@review, Path.join(root, "scripts/locale_catalog_review.exs"))

    File.write!(support, """
    defmodule Marshall.Localization do
      @spec supported_locales() :: [String.t()]
      def supported_locales, do: ["en", "fr"]
    end
    defmodule Marshall.LocalizedMarkdown do
      @spec valid_translation?(String.t(), String.t()) :: boolean()
      def valid_translation?(_, _), do: raise("documentation is outside this fixture")
    end
    """)

    fixture = %{root: root, checker: checker, support: support}
    source = %Singular{msgid: ["Open machine"], msgstr: [""]}
    write_catalog(fixture, "shared.pot", [source], "en")
    write_catalog(fixture, "en/LC_MESSAGES/shared.po", [source], "en")

    write_catalog(
      fixture,
      "fr/LC_MESSAGES/shared.po",
      [%{source | msgstr: ["Ouvrir la machine"]}],
      "fr"
    )

    write_reviews(fixture, [])
    %{fixture: fixture}
  end

  # @cc [owner:ghuntley,label:verification] catalog-check-real-entrypoint
  # Negative catalog fixtures MUST execute the actual checker script in a fresh
  # process and assert its exit status. Default and explicit strict modes MUST
  # refuse every untranslated form while allowing English source fallback.
  test "default and explicit strict entrypoints accept translated catalogs and English fallback",
       %{fixture: fixture} do
    for args <- [[], ["--strict"]] do
      assert {output, 0} = run(fixture, args)
      assert output =~ "en/shared: total=1 empty=1"
      assert output =~ "fr/shared: total=1 empty=0"
    end
  end

  test "empty, whitespace, copied and fuzzy translations fail by default", %{fixture: fixture} do
    for {translation, flags} <- [
          {"", []},
          {" \t", []},
          {"Open machine", []},
          {"Ouvrir la machine", [["fuzzy"]]}
        ] do
      message = %Singular{msgid: ["Open machine"], msgstr: [translation], flags: flags}
      write_catalog(fixture, "fr/LC_MESSAGES/shared.po", [message], "fr")
      assert {output, status} = run(fixture)
      assert status != 0
      assert output =~ "Untranslated catalog entries remain"
    end
  end

  test "one empty or copied plural form fails even when another form is translated", %{
    fixture: fixture
  } do
    source = %Plural{
      msgid: ["%{count} machine"],
      msgid_plural: ["%{count} machines"],
      msgstr: %{0 => [""], 1 => [""]}
    }

    write_catalog(fixture, "shared.pot", [source], "en")
    write_catalog(fixture, "en/LC_MESSAGES/shared.po", [source], "en")

    for second <- ["", "%{count} machines"] do
      target = %{source | msgstr: %{0 => ["%{count} machine française"], 1 => [second]}}
      write_catalog(fixture, "fr/LC_MESSAGES/shared.po", [target], "fr")
      assert {output, status} = run(fixture, ["--strict"])
      assert status != 0
      assert output =~ "Untranslated catalog entries remain"
    end
  end

  test "exact invariant reviews pass but cannot excuse fuzzy or stale forms", %{fixture: fixture} do
    message = %Singular{msgid: ["HTTP"], msgstr: ["HTTP"]}
    write_catalog(fixture, "shared.pot", [%{message | msgstr: [""]}], "en")
    write_catalog(fixture, "en/LC_MESSAGES/shared.po", [message], "en")
    write_catalog(fixture, "fr/LC_MESSAGES/shared.po", [message], "fr")

    review = %{
      "app" => "marshall",
      "locale" => "fr",
      "domain" => "shared",
      "context" => nil,
      "msgid" => "HTTP",
      "msgid_plural" => nil,
      "form" => 0,
      "reason" => "technical_literal",
      "note" => "The HTTP protocol name remains a literal technical identifier."
    }

    write_reviews(fixture, [review])
    assert {output, 0} = run(fixture)
    assert output =~ "reviewed_source_equal=1"

    for target <- [%{message | flags: [["fuzzy"]]}, %{message | msgstr: ["Ouvrir la machine"]}] do
      write_catalog(fixture, "fr/LC_MESSAGES/shared.po", [target], "fr")
      assert {_output, status} = run(fixture, ["--report-only"])
      assert status != 0
    end
  end

  test "report-only diagnoses gaps but never bypasses structural errors or ambiguous flags", %{
    fixture: fixture
  } do
    write_catalog(
      fixture,
      "fr/LC_MESSAGES/shared.po",
      [%Singular{msgid: ["Open machine"], msgstr: [""]}],
      "fr"
    )

    assert {output, 0} = run(fixture, ["--report-only"])
    assert output =~ "fr/shared: total=1 empty=1"

    for args <- [["--strict", "--report-only"], ["--unknown"]] do
      assert {_output, status} = run(fixture, args)
      assert status != 0
    end

    write_catalog(
      fixture,
      "fr/LC_MESSAGES/shared.po",
      [%Singular{msgid: ["Open machine"], msgstr: ["Ouvrir %{missing}"]}],
      "fr"
    )

    assert {output, status} = run(fixture, ["--report-only"])
    assert status != 0
    assert output =~ "Catalog placeholder or documentation structure errors remain"
  end

  test "fuzzy English fallback is refused", %{fixture: fixture} do
    write_catalog(
      fixture,
      "en/LC_MESSAGES/shared.po",
      [%Singular{msgid: ["Open machine"], msgstr: [""], flags: [["fuzzy"]]}],
      "en"
    )

    assert {output, status} = run(fixture)
    assert status != 0
    assert output =~ "Untranslated catalog entries remain"
  end

  @spec run(fixture(), [String.t()]) :: {String.t(), non_neg_integer()}
  defp run(fixture, args \\ []) do
    System.cmd(
      "elixir",
      [
        "-pa",
        Path.join(to_string(:code.lib_dir(:expo)), "ebin"),
        "-r",
        fixture.support,
        fixture.checker | args
      ],
      env: [{"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"}],
      stderr_to_stdout: true
    )
  end

  @spec write_catalog(fixture(), String.t(), [Expo.Message.t()], String.t()) :: :ok
  defp write_catalog(fixture, relative, messages, locale) do
    path = Path.join([fixture.root, "priv/gettext", relative])
    File.mkdir_p!(Path.dirname(path))

    catalog = %Expo.Messages{
      headers: ["Language: #{locale}\n", "Plural-Forms: nplurals=2; plural=(n != 1);\n"],
      messages: messages
    }

    File.write!(path, Expo.PO.compose(catalog))
  end

  @spec write_reviews(fixture(), [review_record()]) :: :ok
  defp write_reviews(fixture, reviews),
    do:
      File.write!(
        Path.join(fixture.root, "priv/gettext/reviewed_source_equal.json"),
        JSON.encode!(reviews)
      )
end
