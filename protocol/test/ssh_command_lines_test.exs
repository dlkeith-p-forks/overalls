defmodule OverallsProtocol.SSHCommandLinesTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.SSHCommand

  # Shared with Mila's Dart encoder and lexer so both sides read lines alike.
  @vectors Path.expand("fixtures/ssh_command_lines.json", __DIR__)
  @external_resource @vectors

  test "shared command lines parse to the same structure Mila encodes" do
    %{"version" => 1, "accepted" => accepted, "refused" => refused} =
      @vectors |> File.read!() |> JSON.decode!()

    for %{"line" => line, "command" => expected} <- accepted do
      assert {:ok, command} = SSHCommand.parse(line), inspect(line)
      assert command.command == expected["command"], inspect(line)
      assert command.arguments == expected["arguments"], inspect(line)
      assert command.options == expected["options"], inspect(line)
    end

    for line <- refused do
      assert {:error, _} = SSHCommand.parse(line), inspect(line)
    end
  end
end
