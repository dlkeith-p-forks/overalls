ExUnit.start()
Code.require_file("fixture.ex", __DIR__)
Code.require_file("guest_witness.ex", __DIR__)

defmodule OverallsAntithesis.GuestWitnessTest do
  use ExUnit.Case, async: true

  alias OverallsAntithesis.GuestWitness

  @request_id "11111111-1111-4111-8111-111111111111"
  @placement_id "22222222-2222-4222-8222-222222222222"

  @type request :: %{required(String.t()) => String.t() | integer()}

  @spec request(String.t()) :: request()
  defp request(operation) do
    %{
      "version" => 1,
      "operation" => operation,
      "request_id" => @request_id,
      "placement_id" => @placement_id,
      "execution_epoch" => 3,
      "generation" => 4
    }
  end

  test "identity uses a fixed image request before any placement exists" do
    identity = %{"version" => 1, "operation" => "guest.identity", "request_id" => @request_id}
    assert :ok = GuestWitness.validate_request(identity, "guest.identity")

    assert_raise MatchError, fn ->
      GuestWitness.validate_request(Map.put(identity, "guest_path", "/tmp"), "guest.identity")
    end
  end

  test "placement requests reject stale and caller-selected fields" do
    witness = request("guest.witness")
    assert :ok = GuestWitness.validate_request(witness, "guest.witness")

    assert_raise ArgumentError, fn ->
      GuestWitness.validate_request(
        Map.put(witness, "operation", "guest.terminal_witness"),
        "guest.witness"
      )
    end

    for changed <- [
          Map.put(witness, "boot_challenge", "a"),
          Map.put(witness, "generation", 0),
          Map.put(witness, "placement_id", "../../guest")
        ] do
      assert_raise MatchError, fn ->
        GuestWitness.validate_request(changed, "guest.witness")
      end
    end
  end

  test "stall request preserves a full 63-bit guest session identity" do
    stall = Map.put(request("guest.terminal_input_stall"), "session_id", "9223372036854775807")
    assert :ok = GuestWitness.validate_request(stall, "guest.terminal_input_stall")

    for invalid <- ["0", "01", "9223372036854775808", "1.0", 1] do
      assert_raise MatchError, fn ->
        GuestWitness.validate_request(
          Map.put(stall, "session_id", invalid),
          "guest.terminal_input_stall"
        )
      end
    end
  end

  test "crash request and receipt bind the exact current QEMU process" do
    crash =
      request("guest.crash")
      |> Map.put("qemu_pid", 242)
      |> Map.put("qemu_start_ticks", 123_456)

    assert :ok = GuestWitness.validate_request(crash, "guest.crash")

    for changed <- [
          Map.put(crash, "qemu_pid", 1),
          Map.put(crash, "qemu_start_ticks", 0),
          Map.put(crash, "signal", "SIGKILL")
        ] do
      assert_raise MatchError, fn -> GuestWitness.validate_request(changed, "guest.crash") end
    end

    receipt = %{
      "version" => 1,
      "request_id" => @request_id,
      "placement_id" => @placement_id,
      "execution_epoch" => 3,
      "generation" => 4,
      "state" => "exited",
      "qemu_pid" => 242,
      "qemu_start_ticks" => 123_456,
      "sent_monotonic_ns" => 1_000_000,
      "exited_monotonic_ns" => 1_500_000
    }

    assert {:ok, ^receipt} = GuestWitness.sanitize_crash_receipt(receipt, crash)

    for changed <- [
          Map.put(receipt, "state", "unavailable"),
          Map.put(receipt, "qemu_start_ticks", 123_457),
          Map.put(receipt, "exited_monotonic_ns", 900_000)
        ] do
      assert {:unavailable, _} = GuestWitness.sanitize_crash_receipt(changed, crash)
    end
  end

  test "replay arm names one terminal and uses separate connection and execution epochs" do
    arm = %{
      "version" => 1,
      "operation" => "terminal.replay_arm",
      "request_id" => @request_id,
      "host_id" => "33333333-3333-4333-8333-333333333333",
      "connection_session_id" => "44444444-4444-4444-8444-444444444444",
      "connection_epoch" => 8,
      "terminal_session_id" => "55555555-5555-4555-8555-555555555555",
      "vm_id" => "66666666-6666-4666-8666-666666666666",
      "placement_id" => @placement_id,
      "execution_epoch" => 3,
      "generation" => 4,
      "guest_session_id" => "9223372036854775807",
      "channel" => 7
    }

    assert :ok = GuestWitness.validate_request(arm, "terminal.replay_arm")

    for changed <- [
          Map.put(arm, "guest_session_id", 9_223_372_036_854_775_807),
          Map.put(arm, "connection_epoch", 0),
          Map.put(arm, "payload", "echo unsafe")
        ] do
      assert_raise MatchError, fn ->
        GuestWitness.validate_request(changed, "terminal.replay_arm")
      end
    end
  end

  test "replay receipt proves only the exact arm's acknowledged channel" do
    receipt_query = %{
      "version" => 1,
      "operation" => "terminal.replay_receipt",
      "request_id" => @request_id,
      "arm_request_id" => @placement_id
    }

    assert :ok = GuestWitness.validate_request(receipt_query, "terminal.replay_receipt")

    assert_raise MatchError, fn ->
      GuestWitness.validate_request(
        Map.put(receipt_query, "arm_request_id", "../other"),
        "terminal.replay_receipt"
      )
    end

    claim = %{"request_id" => @placement_id, "channel" => 7}

    receipt = %{
      "version" => 1,
      "request_id" => @placement_id,
      "state" => "acknowledged",
      "channel" => 7,
      "sequence" => 3,
      "acknowledged_frames" => 3
    }

    assert {:ok, ^receipt} = GuestWitness.sanitize_replay_receipt(receipt, claim)

    for changed <- [
          Map.put(receipt, "state", "armed"),
          Map.put(receipt, "channel", 8),
          Map.put(receipt, "acknowledged_frames", 2),
          Map.put(receipt, "terminal_bytes", "secret")
        ] do
      assert {:unavailable, _} = GuestWitness.sanitize_replay_receipt(changed, claim)
    end
  end

  test "replay arm publication is atomic and cannot replace an active arm" do
    root = Path.join(System.tmp_dir!(), "guest-witness-arm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    active = Path.join(root, "active.json")

    assert :ok =
             GuestWitness.publish_exclusive_arm(
               Path.join(root, ".first.new"),
               active,
               %{"request_id" => @request_id}
             )

    assert %{"request_id" => @request_id} = active |> File.read!() |> JSON.decode!()

    assert {:error, :eexist} =
             GuestWitness.publish_exclusive_arm(
               Path.join(root, ".second.new"),
               active,
               %{"request_id" => @placement_id}
             )

    assert %{"request_id" => @request_id} = active |> File.read!() |> JSON.decode!()
    refute File.exists?(Path.join(root, ".first.new"))
    refute File.exists?(Path.join(root, ".second.new"))
  end

  test "inner guest witness spool accepts only the exact private response ID" do
    root =
      Path.join(System.tmp_dir!(), "guest-witness-spool-#{System.unique_integer([:positive])}")

    requests = Path.join(root, "witness_requests")
    results = Path.join(root, "witness_results")
    File.mkdir_p!(requests)
    File.mkdir_p!(results)
    on_exit(fn -> File.rm_rf!(root) end)

    worker =
      Task.async(fn ->
        path = await_spool_request(requests)

        %{"request_id" => id, "request" => %{"operation" => "identity"}} =
          path |> File.read!() |> JSON.decode!()

        publish_test_response(results, id, %{
          "request_id" => id,
          "response" => %{"state" => "ok"}
        })
      end)

    assert {:ok, %{"state" => "ok"}} =
             GuestWitness.query_spool(root, %{"operation" => "identity"}, 2_000)

    Task.await(worker)
    assert [] == Path.wildcard(Path.join(results, "*.json"))

    # The first request remains on disk in this stub; remove it as the worker does.
    for path <- Path.wildcard(Path.join(requests, "*.json")), do: File.rm!(path)

    wrong_worker =
      Task.async(fn ->
        path = await_spool_request(requests)
        %{"request_id" => id} = path |> File.read!() |> JSON.decode!()

        publish_test_response(results, id, %{
          "request_id" => @request_id,
          "response" => %{"state" => "ok"}
        })
      end)

    assert {:unavailable, _} = GuestWitness.query_spool(root, %{"operation" => "identity"}, 2_000)
    Task.await(wrong_worker)
  end

  @spec await_spool_request(String.t()) :: String.t()
  defp await_spool_request(directory) do
    case Path.wildcard(Path.join(directory, "*.json")) do
      [path] ->
        path

      _ ->
        Process.sleep(10)
        await_spool_request(directory)
    end
  end

  @spec publish_test_response(String.t(), String.t(), map()) :: :ok
  defp publish_test_response(directory, id, value) do
    temporary = Path.join(directory, "." <> id <> ".new")
    File.write!(temporary, JSON.encode!(value))
    File.rename!(temporary, Path.join(directory, id <> ".json"))
  end

  test "witness rejects raw challenges, stale tuples and missing process identities" do
    request = request("guest.witness")

    value = %{
      "state" => "ok",
      "guest_state" => "running",
      "placement_id" => @placement_id,
      "execution_epoch" => 3,
      "generation" => 4,
      "boot_id" => @request_id,
      "ready" => true,
      "qemu" => %{"pid" => 24, "start_ticks" => 200},
      "backend" => %{"pid" => 25, "start_ticks" => 201},
      "boot_challenge_sha256" => String.duplicate("a", 64),
      "image_manifest_sha256" => String.duplicate("b", 64),
      "overlay_present" => true,
      "overlay_bytes" => 4096,
      "overlay_sha256" => nil
    }

    assert {:ok, ^value} = GuestWitness.sanitize("witness", value, request)

    for changed <- [
          Map.put(value, "boot_challenge", String.duplicate("c", 64)),
          Map.put(value, "generation", 5),
          Map.put(value, "qemu", nil),
          Map.put(value, "boot_challenge_sha256", nil)
        ] do
      assert {:unavailable, _} = GuestWitness.sanitize("witness", changed, request)
    end
  end

  test "terminal snapshot admits numeric session IDs and 16-byte ledger digests" do
    value = %{
      "state" => "ok",
      "version" => 1,
      "births" => 1,
      "deaths" => 0,
      "daemon_pid" => 26,
      "daemon_start_ticks" => 120,
      "ring_total" => 10,
      "viewer_total" => 1,
      "ledger_digests" => [String.duplicate("a", 32)],
      "sessions" => [
        %{
          "session_id" => 9_223_372_036_854_775_807,
          "pid" => 25,
          "proc_start_ticks" => 123,
          "alive" => true,
          "ring_base" => 0,
          "ring_tail" => 10,
          "ring_limit" => 100,
          "deque_allocated" => 10,
          "viewers" => [%{"queue_bytes" => 5, "blocked_write" => false}]
        }
      ]
    }

    assert {:ok, ^value} =
             GuestWitness.sanitize("terminal_witness", value, request("guest.terminal_witness"))

    assert {:unavailable, _} =
             GuestWitness.sanitize(
               "terminal_witness",
               put_in(value, ["ledger_digests"], [String.duplicate("a", 64)]),
               request("guest.terminal_witness")
             )
  end
end
