defmodule OverallsProtocol.ExecutionTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.{Execution, VMShape}
  @id "0d9cc041-9db2-4e4c-b28b-1e41d7f472c1"

  test "owner metadata is required, strict and grants no authority" do
    owned = command()
    assert {:ok, ^owned} = owned |> Execution.encode_command() |> Execution.command()

    assert {:error, :invalid_message} =
             owned |> Execution.encode_command() |> Map.delete("owner_id") |> Execution.command()

    assert {:error, :invalid_message} =
             owned
             |> Map.delete(:owner_id)
             |> Execution.encode_command()
             |> List.wrap()
             |> Execution.commands()

    for owner <- [nil, 1, "", "signed-url-fixture", %{"id" => @id}] do
      wire = owned |> Execution.encode_command() |> Map.put("owner_id", owner)
      assert {:error, :invalid_message} = Execution.command(wire)
    end

    wire = owned |> Execution.encode_command() |> Map.delete("execution_epoch")
    assert {:error, :invalid_message} = Execution.command(wire)
    wire = owned |> Execution.encode_command() |> Map.put("owner_name", "untrusted")
    assert {:error, :invalid_message} = Execution.command(wire)
  end

  test "guest SSH keys never enter execution commands" do
    public_key =
      "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 7::256>>)

    for kind <- [:provision, :start, :stop] do
      changed = Map.put(%{command() | kind: kind}, :ssh_public_key, public_key)

      assert {:error, :invalid_message} =
               changed |> Execution.encode_command() |> Execution.command()
    end
  end

  test "Inception execution preserves the fourth profile without accepting unknown profiles" do
    command = %{command() | profile: :inception}
    wire = Execution.encode_command(command)
    assert {:ok, ^command} = Execution.command(wire)
    assert {:error, :invalid_message} = Execution.command(Map.put(wire, "profile", "unknown"))
  end

  test "v4 rejects missing placement authority, invalid epochs and earlier control versions" do
    for decoder <- [&Execution.command/1, &Execution.outcome/1] do
      wire =
        if decoder == (&Execution.command/1),
          do: Execution.encode_command(command()),
          else: Execution.encode_outcome(outcome())

      for field <- ["placement_id", "execution_epoch"] do
        assert {:error, :invalid_message} = decoder.(Map.delete(wire, field))
      end

      for epoch <- [0, -1, nil, 1.0, 9_223_372_036_854_775_808] do
        assert {:error, :invalid_message} = decoder.(Map.put(wire, "execution_epoch", epoch))
      end
    end

    for version <- [1, 2, 3] do
      assert {:error, :unsupported_version} =
               Execution.session(%{
                 "version" => version,
                 "session_id" => @id,
                 "machine_id" => "sha256:" <> String.duplicate("b", 64)
               })
    end
  end

  test "guest readiness is an optional coherent running physical receipt" do
    old = outcome()
    ready = Map.put(old, :guest_ready, true)
    assert {:ok, ^ready} = ready |> Execution.encode_outcome() |> Execution.outcome()
    assert {:ok, ^old} = old |> Execution.encode_outcome() |> Execution.outcome()

    for value <- [false, nil, 1, "true"] do
      assert {:error, :invalid_message} =
               old
               |> Execution.encode_outcome()
               |> Map.put("guest_ready", value)
               |> Execution.outcome()
    end

    stopped = %{ready | state: :stopped, compute_empty: true}

    assert {:error, :invalid_message} =
             stopped |> Execution.encode_outcome() |> Execution.outcome()
  end

  test "different placements of one workload can report in the same batch" do
    first = outcome()

    second = %{
      first
      | id: "11111111-1111-4111-8111-111111111111",
        placement_id: "22222222-2222-4222-8222-222222222222"
    }

    assert {:ok, [^first, ^second]} =
             Execution.outcomes(Enum.map([first, second], &Execution.encode_outcome/1))
  end

  test "resize binds original shape and stable request identity and proves applied sizes" do
    source = OverallsProtocol.Resize.sizes(command())

    resize =
      Map.merge(command(), %{
        kind: :resize,
        resize_from: source,
        resize_id: @id,
        vcpu: 2,
        disk_bytes: 4_294_967_296
      })

    wire = Execution.encode_command(resize)
    assert {:ok, ^resize} = Execution.command(wire)

    for field <- ["resize_from", "resize_id"] do
      assert {:error, :invalid_message} = Execution.command(Map.delete(wire, field))
    end

    assert {:error, :invalid_message} =
             Execution.command(Map.put(wire, "disk_bytes", 1_073_741_824))

    assert {:error, :invalid_message} =
             Execution.command(Map.put(wire, "resize_from", Map.put(source, "extra", 1)))

    proof =
      outcome()
      |> Map.merge(%{
        state: :stopped,
        compute_empty: true,
        applied_sizes: OverallsProtocol.Resize.sizes(resize)
      })

    assert {:ok, ^proof} = Execution.outcome(Execution.encode_outcome(proof))

    assert {:error, :invalid_message} =
             Execution.outcome(
               Execution.encode_outcome(%{proof | state: :running, compute_empty: false})
             )
  end

  defp command do
    %{
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
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2
    }
  end

  defp outcome do
    %{
      id: @id,
      vm_id: @id,
      placement_id: @id,
      execution_epoch: 1,
      operation_id: @id,
      generation: 1,
      sequence: 1,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }
  end

  property "aligned execution shapes round-trip and preserve complete host reservation cost" do
    check all(
            cpu <- integer(1..32),
            mib <- integer(512..262_144),
            pages <- integer(524_288..div(VMShape.maximum_disk_bytes(), 4096)),
            slot <- integer(2..65534),
            generation <- integer(1..9_223_372_036_854_775_807)
          ) do
      command = %{
        command()
        | vcpu: cpu,
          memory_bytes: mib * 1_048_576,
          disk_bytes: pages * 4096,
          slot: slot,
          generation: generation
      }

      assert {:ok, ^command} = Execution.command(Execution.encode_command(command))
      assert VMShape.reservation(command).memory_bytes == command.memory_bytes + 67_108_864

      assert {:error, :invalid_message} =
               Execution.commands([
                 Map.drop(Execution.encode_command(command), ["image_id", "slot"])
               ])
    end
  end

  property "unknown and failed outcomes cannot claim completed deletion" do
    check all(
            state <- member_of([:unknown, :failed]),
            empty <- boolean(),
            disk <- boolean(),
            reason <-
              member_of([
                :unknown,
                :crashed,
                :execution_failed,
                :cleanup_failed,
                :identity_mismatch
              ])
          ) do
      value = %{
        outcome()
        | state: state,
          compute_empty: empty,
          disk_present: disk,
          cleanup_complete: true,
          reason: reason
      }

      assert {:error, :invalid_message} = Execution.outcome(Execution.encode_outcome(value))
    end
  end

  test "physical outcomes retain JSON booleans and reject contradictory observations" do
    for {state, empty, disk, cleanup, reason} <- [
          {:running, false, true, false, :none},
          {:stopped, true, false, false, :none},
          {:stopped, true, true, false, :none},
          {:deleted, true, false, true, :none},
          {:failed, true, true, false, :crashed},
          {:unknown, false, true, false, :unknown}
        ] do
      value = %{
        outcome()
        | state: state,
          compute_empty: empty,
          disk_present: disk,
          cleanup_complete: cleanup,
          reason: reason
      }

      wire = value |> Execution.encode_outcome() |> JSON.encode!() |> JSON.decode!()
      assert {:ok, ^value} = Execution.outcome(wire)
    end

    assert {:error, :invalid_message} =
             Execution.outcome(Execution.encode_outcome(%{outcome() | compute_empty: true}))

    assert {:error, :invalid_message} =
             Execution.command(Execution.encode_command(%{command() | memory_bytes: 536_870_913}))

    assert {:error, :invalid_message} =
             Execution.commands(List.duplicate(Execution.encode_command(command()), 2))
  end

  test "version three requires explicit machine binding and bounded distinct observations" do
    assert {:ok, _} =
             Execution.session(%{
               "version" => 4,
               "session_id" => @id,
               "machine_id" => "sha256:" <> String.duplicate("b", 64)
             })

    assert {:error, :unsupported_version} =
             Execution.session(%{"version" => 1, "session_id" => @id})

    message = %{
      "version" => 4,
      "session_id" => @id,
      "epoch" => 1,
      "report" => nil,
      "acknowledgements" => [],
      "outcomes" => [Execution.encode_outcome(outcome())]
    }

    assert {:ok, _} = Execution.exchange(message)

    assert {:error, :invalid_message} =
             Execution.exchange(%{
               message
               | "outcomes" => List.duplicate(Execution.encode_outcome(outcome()), 17)
             })

    assert {:error, :invalid_message} =
             Execution.exchange(%{
               message
               | "outcomes" => List.duplicate(Execution.encode_outcome(outcome()), 2)
             })
  end
end
