defmodule MarshallWeb.GettextPluralTest do
  use ExUnit.Case, async: true

  alias MarshallWeb.GettextPlural

  test "an explicit catalog rule overrides the locale's zero boundary" do
    context =
      GettextPlural.init(%{
        locale: "en",
        plural_forms_header: "nplurals=2; plural=(n > 1);"
      })

    assert GettextPlural.nplurals(context) == 2
    assert GettextPlural.plural(context, 0) == 0
    assert GettextPlural.plural(context, 1) == 0
    assert GettextPlural.plural(context, 2) == 1
  end

  test "Arabic catalog rules retain all six plural categories" do
    context =
      GettextPlural.init(%{
        locale: "ar",
        plural_forms_header:
          "nplurals=6; plural=(n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5);"
      })

    assert GettextPlural.nplurals(context) == 6

    for {count, expected} <- [{0, 0}, {1, 1}, {2, 2}, {3, 3}, {11, 4}, {100, 5}] do
      assert GettextPlural.plural(context, count) == expected
    end
  end

  test "missing headers retain territory fallback and full generated headers" do
    context = GettextPlural.init(%{locale: "en_US"})

    assert GettextPlural.nplurals(context) == 2
    assert GettextPlural.plural(context, 0) == 1
    assert GettextPlural.plural(context, 1) == 0
    assert GettextPlural.plural(context, 2) == 1
    assert GettextPlural.plural_forms_header("en_US") == "nplurals=2; plural=(n != 1);"
  end
end
