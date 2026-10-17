defmodule OverallsProtocol.InceptionParentTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.InceptionParent

  @parent %{
    "label" => "vm-11111111111141118111111111111111",
    "zone" => "apps.example",
    "origin" => "https://control.example"
  }

  test "closed canonical parent discovery excludes commands and credentials" do
    assert {:ok, @parent} = InceptionParent.validate(@parent)
    assert {:ok, nil} = InceptionParent.validate(nil)

    for origin <- [
          "http://control.example",
          "https://[::1]",
          "https://[::ffff:127.0.0.1]",
          "https://control.example/",
          "https://control.example:443",
          "https://control.example:0443",
          "https://control.example/path",
          "https://control.example?",
          "https://control.example#",
          "https://user@control.example",
          "https://%h",
          "https://$(id)",
          "https://UPPER.example",
          "https://control.example:0",
          "https://control.example:65536",
          <<255>>,
          nil
        ] do
      assert {:error, :invalid_inception_parent} =
               InceptionParent.validate(%{@parent | "origin" => origin})
    end

    for value <- [
          Map.put(@parent, "token", "forbidden"),
          Map.delete(@parent, "origin"),
          %{@parent | "label" => "other"},
          %{@parent | "zone" => "*.example"}
        ] do
      assert {:error, :invalid_inception_parent} = InceptionParent.validate(value)
    end

    assert {:ok, _} =
             InceptionParent.validate(%{@parent | "origin" => "https://control.example:8443"})
  end
end
