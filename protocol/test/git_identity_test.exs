defmodule OverallsProtocol.GitIdentityTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.{Execution, GitIdentity, WorkspaceSource}
  @id "0d9cc041-9db2-4e4c-b28b-1e41d7f472c1"

  property "bounded attribution survives JSON without normalization",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 481_293_107 do
    name = draw("name", string(:alphanumeric, min_length: 1, max_length: 128))
    local = draw("local", string(:alphanumeric, min_length: 1, max_length: 64))
    domain = draw("domain", string(:alphanumeric, min_length: 1, max_length: 64))
    identity = %{name: name, email: local <> "@" <> domain <> ".example"}
    assert GitIdentity.valid?(identity)
    assert {:ok, ^identity} = GitIdentity.validate(identity)
    wire = identity |> GitIdentity.encode() |> JSON.encode!() |> JSON.decode!()
    assert {:ok, ^identity} = GitIdentity.decode(wire)

    for key <- ["version", "name", "email"] do
      assert {:error, :invalid_message} = GitIdentity.decode(Map.delete(wire, key))
    end

    assert {:error, :invalid_message} = GitIdentity.decode(Map.put(wire, "extra", "value"))
    assert {:error, :invalid_message} = GitIdentity.decode(Map.put(wire, "version", 2))
  end

  property "attribution composes with repository metadata only on provision and start",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 481_293_108 do
    kind = draw("kind", member_of([:provision, :start, :stop, :delete, :resize]))
    source? = draw("source", boolean())
    identity = %{name: "José Example", email: "person+git@example.test"}
    command = Map.put(command(), :kind, kind)

    command =
      if kind == :resize,
        do: Map.merge(command, %{resize_id: @id, resize_from: sizes()}),
        else: command

    {:ok, source} = WorkspaceSource.parse_url("https://github.com/example/repository")
    command = if source?, do: Map.put(command, :workspace_source, source), else: command
    attributed = Map.put(command, :git_identity, identity)
    wire = attributed |> Execution.encode_command() |> JSON.encode!() |> JSON.decode!()

    if kind in [:provision, :start] do
      assert {:ok, ^attributed} = Execution.command(wire)
      assert {:ok, [^attributed]} = Execution.commands([wire])
      assert {:ok, ^command} = command |> Execution.encode_command() |> Execution.command()
      assert {:error, :invalid_message} = Execution.command(Map.delete(wire, "owner_id"))
    else
      assert {:error, :invalid_message} = Execution.command(wire)
    end

    assert {:error, :invalid_message} =
             Execution.command(put_in(wire, ["git_identity", "email"], "bad\n@example.test"))

    assert {:error, :invalid_message} = Execution.command(put_in(wire, ["execution_epoch"], 0))
  end

  test "name and mailbox boundaries refuse injection, invalid encoding and oversized values" do
    identity = %{
      name: String.duplicate("é", 64),
      email: String.duplicate("a", 242) <> "@example.com"
    }

    assert GitIdentity.valid?(identity)

    for name <- [
          "",
          " ",
          " name",
          "name ",
          "a\nb",
          "a\0b",
          "a\tb",
          "a<b",
          "a>b",
          <<255>>,
          String.duplicate("é", 65),
          "a\u200Bb"
        ] do
      refute GitIdentity.valid?(%{identity | name: name})
    end

    for email <- [
          "",
          "plain",
          "a..b@example.com",
          ".a@example.com",
          "a.@example.com",
          "a@example..com",
          "a@-example.com",
          "a@example-.com",
          "@example.com",
          "a@",
          "a b@example.com",
          "a\n@example.com",
          "a\0@example.com",
          "a<b>@example.com",
          "a@example.com>",
          "a,b@example.com",
          "a;b@example.com",
          "a\"b@example.com",
          "é@example.com",
          <<255>>,
          String.duplicate("a", 243) <> "@example.com"
        ] do
      refute GitIdentity.valid?(%{identity | email: email})
    end

    refute GitIdentity.valid?(Map.put(identity, :authority, true))
    refute GitIdentity.valid?(nil)
  end

  @spec sizes() :: %{vcpu: pos_integer(), memory_bytes: pos_integer(), disk_bytes: pos_integer()}
  defp sizes, do: %{vcpu: 1, memory_bytes: 536_870_912, disk_bytes: 2_147_483_648}

  @spec command() :: Execution.command()
  defp command do
    Map.merge(sizes(), %{
      id: @id,
      owner_id: @id,
      vm_id: @id,
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      generation: 1,
      kind: :provision,
      architecture: :x86_64,
      profile: :oss,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2
    })
  end
end
