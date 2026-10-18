defmodule OverallsProtocol.ReflectionTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen

  alias OverallsProtocol.Reflection

  # @cc [owner:ghuntley,label:security;verification] reflection-comment-bounds-oracle
  # Generated comment checks MUST include the byte limit, invalid UTF-8 and NUL;
  # only valid UTF-8 without NUL at or below 2048 bytes MAY round-trip.
  property "comments are bounded and never accept NUL bytes", test_cases: 100 do
    value =
      draw(
        "comment",
        one_of([
          binary(max_length: 2_050),
          string(:printable, max_length: 2_050),
          member_of([String.duplicate("x", 2_048), String.duplicate("x", 2_049), "a\0b", <<255>>])
        ])
      )

    result = Reflection.comment(value)

    if byte_size(value) <= 2048 and String.valid?(value) and not String.contains?(value, "\0") do
      assert {:ok, ^value} = result
    else
      assert {:error, :invalid_comment} = result
    end
  end

  test "rejects snapshots with secret-shaped header values" do
    refute match?(
             {:ok, _},
             Reflection.snapshot(%{
               "version" => 1,
               "guest" => %{},
               "integrations" => [
                 %{"headers" => [%{"name" => "authorization", "value" => "secret"}]}
               ]
             })
           )
  end
end
