defmodule OverallsProtocol.InceptionPublicTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.InceptionPublic

  test "public operator settings share the exact guest validation corpus" do
    cases =
      __DIR__ |> Path.join("fixtures/inception_public.json") |> File.read!() |> JSON.decode!()

    for example <- cases do
      expected =
        if example["valid"],
          do: {:ok, example["value"]},
          else: {:error, :invalid_inception_public}

      assert InceptionPublic.validate(example["value"]) == expected, example["name"]
    end
  end
end
