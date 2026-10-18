defmodule OverallsProtocol.ReflectionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OverallsProtocol.Reflection

  property "comments are bounded and never accept NUL bytes" do
    check all(value <- binary()) do
      result = Reflection.comment(value)

      if byte_size(value) <= 2048 and String.valid?(value) and not String.contains?(value, "\0") do
        assert {:ok, ^value} = result
      else
        assert {:error, :invalid_comment} = result
      end
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
