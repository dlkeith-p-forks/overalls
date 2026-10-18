defmodule Lilly.Transfer.ExportRequestTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Transfer.ExportRequest
  @relocation "00000000-0000-0000-0000-000000000001"
  @command "lilly-export-v4 #{@relocation}"

  test "only the closed command grammar is accepted" do
    assert {:ok, %{relocation_id: @relocation} = request} = ExportRequest.parse(@command)
    assert map_size(request) == 1

    for command <- [
          nil,
          [],
          %{},
          "",
          "sh",
          " " <> @command,
          @command <> " ",
          @command <> "\n",
          @command <> "\r",
          @command <> "\0",
          @command <> ";id",
          @command <> " /pool/vm",
          @command <> " $(id)",
          @command <> " `id`",
          String.replace(@command, " ", "\t"),
          String.replace(@command, " ", "  "),
          String.replace(@command, @relocation, "../../etc/passwd"),
          "lilly-export-v4 '#{@relocation}'",
          "lilly-export-v4 \"#{@relocation}\"",
          # ADR-0155 removed stream kinds and the v3 grammar that carried them.
          @command <> " full",
          "lilly-export-v3 #{@relocation} full",
          "lilly-export-v3 #{@relocation} baseline",
          "lilly-export-v3 #{@relocation} incremental"
        ] do
      assert {:error, :export_permit_unconfirmed} = ExportRequest.parse(command)
    end
  end

  test "resume syntax is bounded and cannot introduce shell arguments" do
    token = "1-a-10-aabb"
    command = "lilly-resume-v4 #{@relocation} "

    assert {:ok, %{relocation_id: @relocation, resume_token: ^token} = request} =
             ExportRequest.parse(command <> token)

    assert map_size(request) == 2

    for invalid <- [
          "",
          token <> " ",
          token <> ";id",
          token <> "\n",
          "full " <> token,
          "1-a-10-abc",
          "1-a-10-$(id)",
          String.duplicate("a", 8193)
        ] do
      assert {:error, :export_permit_unconfirmed} = ExportRequest.parse(command <> invalid)
    end

    for legacy <- [
          "lilly-resume-v3 #{@relocation} full #{token}",
          "lilly-resume-v3 #{@relocation} incremental #{token}"
        ] do
      assert {:error, :export_permit_unconfirmed} = ExportRequest.parse(legacy)
    end
  end

  test "RAM has a separate closed command and never accepts a resume token or paths" do
    command = "lilly-checkpoint-v1 #{@relocation}"

    assert {:ok, %{relocation_id: @relocation, component: :checkpoint}} =
             ExportRequest.parse(command)

    for invalid <- [
          command <> " ",
          command <> " 1-a-10-aabb",
          command <> " /memory",
          command <> ";id",
          command <> "\n",
          String.replace(command, " ", "\t"),
          "lilly-checkpoint-v2 #{@relocation}"
        ] do
      assert {:error, :export_permit_unconfirmed} = ExportRequest.parse(invalid)
    end
  end

  property "arbitrary bytes can only decode to the exact canonical grammar" do
    check all(bytes <- binary(max_length: 256)) do
      case ExportRequest.parse(bytes) do
        {:ok, request} ->
          expected =
            case request do
              %{component: :checkpoint} -> "lilly-checkpoint-v1 #{request.relocation_id}"
              %{resume_token: token} -> "lilly-resume-v4 #{request.relocation_id} #{token}"
              _ -> "lilly-export-v4 #{request.relocation_id}"
            end

          assert bytes == expected
          assert OverallsProtocol.uuid?(request.relocation_id)

        result ->
          assert result == {:error, :export_permit_unconfirmed}
      end
    end
  end
end
