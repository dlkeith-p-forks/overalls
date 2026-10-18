defmodule Galileo.StripTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Galileo.Strip

  property "prefix removal is segment-aligned and never rewrites unmatched paths" do
    segments =
      draw(
        "segments",
        list_of(string(:alphanumeric, min_length: 1, max_length: 8), min_length: 1, max_length: 6)
      )

    extra =
      draw(
        "extra",
        list_of(string(:alphanumeric, min_length: 1, max_length: 8), min_length: 0, max_length: 4)
      )

    prefix = "/" <> Enum.join(segments, "/")
    path = "/" <> Enum.join(segments ++ extra, "/")
    expected = if extra == [], do: "/", else: "/" <> Enum.join(extra, "/")

    assert Strip.apply(prefix, path) == expected
    assert Strip.apply(prefix, path <> "/") == expected
  end

  test "similar prefixes do not match" do
    assert Strip.apply("/api/v3", "/api/v3x/other") == "/api/v3x/other"
    assert Strip.apply("/api/v3", "/api/v4/users") == "/api/v4/users"
    assert Strip.apply("/api/v3", "/api/v3") == "/"
    assert Strip.apply("/api/v3", "/api/v3/") == "/"
    assert Strip.apply("/api/v3", "/api/v3/users") == "/users"
    assert Strip.apply(nil, "/api/v3/users") == "/api/v3/users"
    assert Strip.apply("/api/v3", "*") == "*"
    assert Strip.apply("/api/v3", "") == ""
  end
end
