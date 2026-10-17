# @cc [owner:ghuntley,label:security;verification] guest-witness-private-boundary
# Only the enrollment operator may query the fixed guest-vmm witness socket.
# Placement observations MUST name a current Marshall placement, epoch and generation; the
# workload MUST receive only validated, sanitized witness fields. Missing or
# stale evidence MUST remain unavailable, never become an empty observation.
defmodule OverallsAntithesis.GuestWitness do
  @moduledoc "Closed, sanitized witness of the current integrated guest."

  alias OverallsAntithesis.Fixture
  alias Marshall.Compute.{Host, Ledger, VirtualMachine, WorkloadPlacement}
  alias Marshall.Terminal.{Directory, Session}

  @operations ~w(guest.identity guest.witness guest.terminal_witness guest.terminal_input_stall guest.crash terminal.replay_arm terminal.replay_receipt)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @ledger_digest ~r/\A[0-9a-f]{32}\z/
  @max_integer 9_007_199_254_740_991
  @max_unsigned 18_446_744_073_709_551_615
  @max_response_bytes 16_384
  @socket "/run/overalls-guest-witness/witness.sock"
  @fault_root "/run/overalls-faults"
  @replay_root "/run/overalls-terminal-replay"

  @type request :: %{required(String.t()) => String.t() | pos_integer()}
  @type process_witness :: %{required(String.t()) => pos_integer()}
  @type image_identity :: %{required(String.t()) => String.t() | pos_integer() | nil}
  @type guest_witness :: %{
          required(String.t()) =>
            String.t() | non_neg_integer() | boolean() | nil | process_witness()
        }
  @type viewer_witness :: %{required(String.t()) => non_neg_integer() | boolean()}
  @type terminal_session :: %{
          required(String.t()) => non_neg_integer() | boolean() | [viewer_witness()]
        }
  @type terminal_snapshot :: %{
          required(String.t()) =>
            String.t() | non_neg_integer() | [terminal_session()] | [String.t()]
        }
  @type stall_witness :: %{
          required(String.t()) => String.t() | non_neg_integer() | boolean()
        }
  @type crash_receipt :: %{required(String.t()) => String.t() | pos_integer()}
  @type replay_arm :: %{required(String.t()) => String.t() | pos_integer()}
  @type witness_value ::
          image_identity()
          | guest_witness()
          | terminal_snapshot()
          | stall_witness()
          | crash_receipt()
          | replay_arm()
  @type result :: {:ok, witness_value()} | {:unavailable, String.t()}

  # @cc [owner:ghuntley,label:security;verification] guest-witness-current-only
  # A successful placement receipt MUST be based on the current Marshall tuple
  # and one matching guest-vmm witness. The operator MUST NOT return raw
  # boot challenges, terminal bytes, arbitrary guest paths, or socket errors.
  @spec main([String.t()]) :: :ok | no_return()
  def main([operation, manifest_path, request_path, result_path]) when operation in @operations do
    true = System.get_env("MARSHALL_INSTANCE_ID") == "enrollment-operator"
    true = Application.get_env(:marshall, :operator_mode) == true
    true = File.regular?("/run/overalls-oracle/fixture.json")
    manifest = Fixture.read_manifest!(manifest_path)
    request = request_path |> File.read!() |> JSON.decode!()
    :ok = validate_request(request, operation)

    result =
      case operation do
        "guest.identity" ->
          query("identity", request)

        "terminal.replay_receipt" ->
          read_replay_receipt(request)

        "guest.crash" ->
          with :ok <- current_tuple(request, manifest),
               {:ok, witness} <- query("witness", request),
               :ok <- validate_crash_witness(witness, request),
               :ok <- current_tuple(request, manifest),
               {:ok, value} <- issue_crash(request) do
            {:ok, value}
          else
            {:unavailable, reason} -> {:unavailable, reason}
          end

        "terminal.replay_arm" ->
          with :ok <- current_tuple(request, manifest),
               :ok <- current_replay_binding(request, manifest),
               :ok <- current_tuple(request, manifest),
               {:ok, value} <- issue_replay_arm(request) do
            {:ok, value}
          else
            {:unavailable, reason} -> {:unavailable, reason}
          end

        _ ->
          with :ok <- current_tuple(request, manifest),
               {:ok, value} <- observe(operation, request),
               :ok <- current_tuple(request, manifest) do
            {:ok, value}
          else
            {:unavailable, reason} -> {:unavailable, reason}
          end
      end

    receipt =
      case result do
        {:ok, value} -> envelope(request, operation, "ok", %{value: value})
        {:unavailable, reason} -> envelope(request, operation, "unavailable", %{reason: reason})
      end

    Fixture.write_private!(result_path, receipt)
  rescue
    _ -> System.halt(1)
  catch
    _, _ -> System.halt(1)
  end

  def main(_), do: System.halt(1)

  @doc false
  @spec validate_request(term(), String.t()) :: :ok | no_return()
  def validate_request(
        %{"version" => 1, "operation" => "guest.identity", "request_id" => request_id} = request,
        "guest.identity"
      ) do
    true = Enum.sort(Map.keys(request)) == ~w(operation request_id version)
    true = uuid?(request_id)
    :ok
  end

  def validate_request(
        %{
          "version" => 1,
          "operation" => "terminal.replay_receipt",
          "request_id" => request_id,
          "arm_request_id" => arm_request_id
        } = request,
        "terminal.replay_receipt"
      ) do
    true = Enum.sort(Map.keys(request)) == ~w(arm_request_id operation request_id version)
    true = uuid?(request_id) and uuid?(arm_request_id)
    :ok
  end

  def validate_request(
        %{
          "version" => 1,
          "operation" => operation,
          "request_id" => request_id,
          "placement_id" => placement_id,
          "execution_epoch" => epoch,
          "generation" => generation
        } = request,
        operation
      )
      when operation in @operations do
    expected =
      case operation do
        "guest.terminal_input_stall" ->
          ~w(execution_epoch generation operation placement_id request_id session_id version)

        "guest.crash" ->
          ~w(execution_epoch generation operation placement_id qemu_pid qemu_start_ticks request_id version)

        "terminal.replay_arm" ->
          ~w(channel connection_epoch connection_session_id execution_epoch generation guest_session_id host_id operation placement_id request_id terminal_session_id version vm_id)

        _ ->
          ~w(execution_epoch generation operation placement_id request_id version)
      end

    true = Enum.sort(Map.keys(request)) == expected
    true = uuid?(request_id) and uuid?(placement_id)
    true = positive_number?(epoch) and positive_number?(generation)

    if operation == "guest.terminal_input_stall" do
      true = session_id?(request["session_id"])
    end

    if operation == "guest.crash" do
      true = positive_number?(request["qemu_pid"]) and request["qemu_pid"] > 1
      true = positive_number?(request["qemu_start_ticks"])
    end

    if operation == "terminal.replay_arm" do
      true =
        Enum.all?(
          ~w(host_id connection_session_id terminal_session_id vm_id),
          &uuid?(request[&1])
        )

      true = positive_number?(request["connection_epoch"])
      true = positive_number?(request["channel"])
      true = session_id?(request["guest_session_id"])
    end

    :ok
  end

  def validate_request(_, _), do: raise(ArgumentError, "invalid guest witness request")

  @spec current_tuple(request(), map()) :: :ok | {:unavailable, String.t()}
  defp current_tuple(request, manifest) do
    placement_id = request["placement_id"]
    fixture_owners = for name <- ~w(admin_a admin_b target), do: get_in(manifest, [name, "id"])

    with true <- Enum.all?(fixture_owners, &uuid?/1),
         [placement] <- Ledger.read!(WorkloadPlacement, id: placement_id),
         [vm] <- Ledger.read!(VirtualMachine, id: placement.vm_id),
         true <- vm.current_placement_id == placement_id,
         true <- vm.execution_epoch == request["execution_epoch"],
         true <- vm.generation == request["generation"],
         true <- vm.owner_id in fixture_owners,
         true <- is_nil(vm.archived_at) do
      :ok
    else
      _ -> {:unavailable, "current_placement_unavailable"}
    end
  rescue
    _ -> {:unavailable, "current_placement_unavailable"}
  end

  @spec current_replay_binding(request(), map()) :: :ok | {:unavailable, String.t()}
  defp current_replay_binding(request, manifest) do
    owners = for name <- ~w(admin_a admin_b target), do: get_in(manifest, [name, "id"])

    with true <- Enum.all?(owners, &uuid?/1),
         [placement] <- Ledger.read!(WorkloadPlacement, id: request["placement_id"]),
         [vm] <- Ledger.read!(VirtualMachine, id: request["vm_id"]),
         [host] <- Ledger.read!(Host, id: request["host_id"]),
         {:ok, %Session{} = session} <-
           Ash.get(Session, request["terminal_session_id"], authorize?: false),
         true <- placement.vm_id == vm.id and placement.host_id == host.id,
         true <- vm.current_placement_id == placement.id and vm.host_id == host.id,
         true <- vm.execution_epoch == request["execution_epoch"],
         true <- vm.generation == request["generation"],
         true <- vm.owner_id in owners and session.owner_id in owners,
         true <- is_nil(vm.archived_at) and is_nil(session.archived_at),
         true <- vm.desired_state == :running and vm.observed_state == :running,
         true <- session.kill_status == :idle,
         true <- session.vm_id == vm.id and session.placement_id == placement.id,
         true <- session.execution_epoch == request["execution_epoch"],
         true <- session.guest_session_id == String.to_integer(request["guest_session_id"]),
         true <- host.connection_session_id == request["connection_session_id"],
         true <- host.connection_epoch == request["connection_epoch"],
         true <-
           Directory.current_execution?(
             host.id,
             host.connection_session_id,
             host.connection_epoch
           ) do
      :ok
    else
      _ -> {:unavailable, "current_terminal_unavailable"}
    end
  rescue
    _ -> {:unavailable, "current_terminal_unavailable"}
  end

  # @cc [owner:ghuntley,label:security;verification] terminal-replay-exclusive-arm
  # An arm MUST publish only the exact current fixture terminal and authenticated
  # host connection. One active arm may exist at a time. Publication proves only
  # that the hook is armed; acknowledged delivery requires a later receipt.
  @spec issue_replay_arm(request()) :: result()
  defp issue_replay_arm(request) do
    root = System.get_env("OVERALLS_ANTITHESIS_TERMINAL_REPLAY_ROOT", @replay_root)
    active = Path.join(root, "active.json")
    claimed_dir = Path.join(root, "claimed")
    receipts_dir = Path.join(root, "receipts")
    arm_id = request["request_id"]
    temporary = Path.join(root, "." <> arm_id <> ".new")

    payload = %{
      "version" => 1,
      "request_id" => arm_id,
      "host_id" => request["host_id"],
      "connection_session_id" => request["connection_session_id"],
      "connection_epoch" => request["connection_epoch"],
      "terminal_session_id" => request["terminal_session_id"],
      "vm_id" => request["vm_id"],
      "placement_id" => request["placement_id"],
      "execution_epoch" => request["execution_epoch"],
      "guest_session_id" => String.to_integer(request["guest_session_id"]),
      "channel" => request["channel"]
    }

    with true <- private_directory?(root),
         :ok <- File.mkdir_p(claimed_dir),
         :ok <- File.mkdir_p(receipts_dir),
         true <- private_directory?(claimed_dir) and private_directory?(receipts_dir),
         false <- File.exists?(Path.join(claimed_dir, arm_id <> ".json")),
         false <- File.exists?(Path.join(receipts_dir, arm_id <> ".json")),
         :ok <- publish_exclusive_arm(temporary, active, payload) do
      {:ok, %{"state" => "armed", "request_id" => arm_id}}
    else
      _ -> {:unavailable, "terminal_replay_unavailable"}
    end
  rescue
    _ -> {:unavailable, "terminal_replay_unavailable"}
  end

  @doc false
  @spec publish_exclusive_arm(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def publish_exclusive_arm(temporary, active, payload) do
    bytes = JSON.encode!(payload)

    if byte_size(bytes) > 2_048 do
      {:error, :oversized_arm}
    else
      with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]) do
        result =
          try do
            with :ok <- IO.binwrite(file, bytes),
                 :ok <- :file.sync(file),
                 :ok <- File.chmod(temporary, 0o600) do
              :ok
            end
          after
            File.close(file)
          end

        linked = if result == :ok, do: File.ln(temporary, active), else: result
        File.rm(temporary)
        linked
      end
    end
  end

  @spec read_replay_receipt(request()) :: result()
  defp read_replay_receipt(request) do
    root = System.get_env("OVERALLS_ANTITHESIS_TERMINAL_REPLAY_ROOT", @replay_root)
    arm_id = request["arm_request_id"]
    claim_path = Path.join([root, "claimed", arm_id <> ".json"])
    receipt_path = Path.join([root, "receipts", arm_id <> ".json"])

    with true <- private_directory?(Path.join(root, "claimed")),
         true <- private_directory?(Path.join(root, "receipts")),
         {:ok, claim} <- read_private_object(claim_path, 2_048),
         :ok <- validate_replay_claim(claim, arm_id),
         {:ok, receipt} <- read_private_object(receipt_path, 1_024),
         {:ok, value} <- sanitize_replay_receipt(receipt, claim) do
      {:ok, value}
    else
      _ -> {:unavailable, "terminal_replay_unavailable"}
    end
  rescue
    _ -> {:unavailable, "terminal_replay_unavailable"}
  end

  @spec read_private_object(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  defp read_private_object(path, maximum) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= maximum <-
           File.lstat(path),
         {:ok, bytes} when byte_size(bytes) <= maximum <- File.read(path),
         {:ok, %{} = decoded} <- JSON.decode(bytes) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_private_object}
    end
  end

  @spec validate_replay_claim(map(), String.t()) :: :ok | {:error, :invalid_claim}
  defp validate_replay_claim(claim, arm_id) do
    keys =
      ~w(channel connection_epoch connection_session_id execution_epoch guest_session_id host_id placement_id request_id terminal_session_id version vm_id)

    valid =
      Enum.sort(Map.keys(claim)) == keys and claim["version"] == 1 and
        claim["request_id"] == arm_id and
        Enum.all?(
          ~w(host_id connection_session_id terminal_session_id vm_id placement_id),
          &uuid?(claim[&1])
        ) and positive_number?(claim["connection_epoch"]) and
        positive_number?(claim["execution_epoch"]) and
        positive_number?(claim["channel"]) and positive_u63?(claim["guest_session_id"])

    if valid, do: :ok, else: {:error, :invalid_claim}
  end

  @doc false
  @spec sanitize_replay_receipt(term(), map()) :: result()
  def sanitize_replay_receipt(receipt, claim) when is_map(receipt) and is_map(claim) do
    keys = ~w(acknowledged_frames channel request_id sequence state version)

    with true <- Enum.sort(Map.keys(receipt)) == keys,
         true <- receipt["version"] == 1 and receipt["state"] == "acknowledged",
         true <- receipt["request_id"] == claim["request_id"],
         true <- receipt["channel"] == claim["channel"],
         true <- positive_number?(receipt["sequence"]),
         true <- positive_number?(receipt["acknowledged_frames"]),
         true <- receipt["acknowledged_frames"] >= receipt["sequence"] do
      {:ok, receipt}
    else
      _ -> {:unavailable, "terminal_replay_unavailable"}
    end
  end

  def sanitize_replay_receipt(_, _), do: {:unavailable, "terminal_replay_unavailable"}

  @spec query_operation(String.t()) :: String.t()
  defp query_operation("guest.identity"), do: "identity"
  defp query_operation("guest.witness"), do: "witness"
  defp query_operation("guest.terminal_witness"), do: "terminal_witness"
  defp query_operation("guest.terminal_input_stall"), do: "terminal_input_stall"

  @spec observe(String.t(), request()) :: result()
  defp observe("guest.witness", request), do: query("witness", request)

  defp observe(operation, request) do
    with {:ok, witness} <- query("witness", request),
         true <- witness["guest_state"] == "running" and witness["ready"],
         {:ok, value} <- query(query_operation(operation), request) do
      {:ok, value}
    else
      _ -> {:unavailable, "guest_witness_unavailable"}
    end
  end

  @spec validate_crash_witness(witness_value(), request()) ::
          :ok | {:unavailable, String.t()}
  defp validate_crash_witness(witness, request) do
    if witness["guest_state"] == "running" and witness["ready"] and
         witness["qemu"] == %{
           "pid" => request["qemu_pid"],
           "start_ticks" => request["qemu_start_ticks"]
         } and is_map(witness["backend"]) do
      :ok
    else
      {:unavailable, "guest_fault_authority_unavailable"}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] guest-crash-closed-fault
  # Only an exact current, ready QEMU process identity may be sent to the
  # private fault worker. A missing, mismatched or late exit receipt MUST be
  # unavailable; the operator MUST NOT infer exit from request publication.
  # A confirmed receipt proves only that QEMU PID exited, not backend recovery.
  @spec issue_crash(request()) :: result()
  defp issue_crash(request) do
    root = System.get_env("OVERALLS_ANTITHESIS_GUEST_FAULT_ROOT", @fault_root)
    request_dir = Path.join(root, "requests")
    receipt_path = Path.join([root, "receipts", request["request_id"] <> ".json"])
    destination = Path.join(request_dir, request["request_id"] <> ".json")

    temporary =
      Path.join(
        request_dir,
        "." <>
          request["request_id"] <>
          "." <>
          Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> ".new"
      )

    payload = %{
      "version" => 1,
      "operation" => "crash_guest",
      "request_id" => request["request_id"],
      "placement_id" => request["placement_id"],
      "execution_epoch" => request["execution_epoch"],
      "generation" => request["generation"],
      "qemu_pid" => request["qemu_pid"],
      "qemu_start_ticks" => request["qemu_start_ticks"]
    }

    with true <-
           private_directory?(request_dir) and private_directory?(Path.dirname(receipt_path)),
         false <- File.exists?(destination) or File.exists?(receipt_path),
         :ok <- write_fault_request(temporary, destination, payload) do
      await_crash_receipt(receipt_path, request, System.monotonic_time(:millisecond) + 10_000)
    else
      _ -> {:unavailable, "guest_fault_unavailable"}
    end
  rescue
    _ -> {:unavailable, "guest_fault_unavailable"}
  end

  @spec private_directory?(String.t()) :: boolean()
  defp private_directory?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} -> Bitwise.band(mode, 0o002) == 0
      _ -> false
    end
  end

  @spec write_fault_request(String.t(), String.t(), map()) :: :ok | {:error, term()}
  defp write_fault_request(temporary, destination, payload) do
    with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]) do
      result =
        try do
          with :ok <- IO.binwrite(file, JSON.encode!(payload)),
               :ok <- :file.sync(file),
               :ok <- File.chmod(temporary, 0o600) do
            :ok
          end
        after
          File.close(file)
        end

      case result do
        :ok -> File.rename(temporary, destination)
        error -> error
      end
    end
  end

  @spec await_crash_receipt(String.t(), request(), integer()) :: result()
  defp await_crash_receipt(path, request, deadline) do
    response =
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} when size <= 4_096 -> File.read(path)
        {:error, :enoent} -> {:error, :enoent}
        _ -> {:error, :invalid_receipt}
      end

    case response do
      {:ok, bytes} when byte_size(bytes) <= 4_096 ->
        with {:ok, raw} <- JSON.decode(bytes),
             {:ok, value} <- sanitize_crash_receipt(raw, request) do
          {:ok, value}
        else
          _ -> {:unavailable, "guest_fault_unavailable"}
        end

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          await_crash_receipt(path, request, deadline)
        else
          {:unavailable, "guest_fault_unavailable"}
        end

      _ ->
        {:unavailable, "guest_fault_unavailable"}
    end
  end

  @doc false
  @spec sanitize_crash_receipt(term(), request()) :: result()
  def sanitize_crash_receipt(raw, request) when is_map(raw) do
    keys =
      ~w(execution_epoch exited_monotonic_ns generation placement_id qemu_pid qemu_start_ticks request_id sent_monotonic_ns state version)

    with true <- Enum.sort(Map.keys(raw)) == keys,
         true <- raw["version"] == 1 and raw["state"] == "exited",
         true <- raw["request_id"] == request["request_id"],
         true <- raw["placement_id"] == request["placement_id"],
         true <- raw["execution_epoch"] == request["execution_epoch"],
         true <- raw["generation"] == request["generation"],
         true <- raw["qemu_pid"] == request["qemu_pid"],
         true <- raw["qemu_start_ticks"] == request["qemu_start_ticks"],
         true <- positive_u63?(raw["sent_monotonic_ns"]),
         true <- positive_u63?(raw["exited_monotonic_ns"]),
         true <- raw["exited_monotonic_ns"] >= raw["sent_monotonic_ns"] do
      {:ok, raw}
    else
      _ -> {:unavailable, "guest_fault_unavailable"}
    end
  end

  def sanitize_crash_receipt(_, _), do: {:unavailable, "guest_fault_unavailable"}

  @spec query(String.t(), request()) :: result()
  defp query(operation, request) do
    payload =
      if operation == "identity" do
        %{"operation" => operation}
      else
        %{
          "operation" => operation,
          "placement_id" => request["placement_id"],
          "execution_epoch" => request["execution_epoch"],
          "generation" => request["generation"]
        }
      end

    payload =
      if operation == "terminal_input_stall",
        do: Map.put(payload, "session_id", String.to_integer(request["session_id"])),
        else: payload

    response =
      case System.get_env("OVERALLS_ANTITHESIS_GUEST_WITNESS_ROOT") do
        nil -> query_socket(payload, operation)
        root -> query_spool(root, payload, if(operation == "witness", do: 45_000, else: 10_000))
      end

    with {:ok, raw} <- response,
         {:ok, value} <- sanitize(operation, raw, request) do
      {:ok, value}
    else
      _ -> {:unavailable, "guest_witness_unavailable"}
    end
  rescue
    _ -> {:unavailable, "guest_witness_unavailable"}
  end

  @spec query_socket(map(), String.t()) :: {:ok, map()} | {:unavailable, String.t()}
  defp query_socket(payload, operation) do
    socket_path = System.get_env("OVERALLS_ANTITHESIS_GUEST_WITNESS_SOCKET", @socket)

    with {:ok, socket} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(socket_path)},
             0,
             [:binary, packet: :line, packet_size: @max_response_bytes, active: false],
             3_000
           ) do
      try do
        with :ok <- :gen_tcp.send(socket, JSON.encode!(payload) <> "\n"),
             {:ok, line} <-
               :gen_tcp.recv(socket, 0, if(operation == "witness", do: 35_000, else: 5_000)),
             true <- byte_size(line) <= @max_response_bytes,
             {:ok, %{} = raw} <- JSON.decode(line) do
          {:ok, raw}
        else
          _ -> {:unavailable, "guest_witness_unavailable"}
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> {:unavailable, "guest_witness_unavailable"}
    end
  rescue
    _ -> {:unavailable, "guest_witness_unavailable"}
  end

  # @cc [owner:ghuntley,label:security;verification] inner-guest-witness-spool
  # The hosted inner-VM selection MUST carry only one fixed witness request and
  # its exact matching response over the private spool. A missing, oversized or
  # mismatched result MUST be unavailable and MUST NOT fall back to another path.
  @doc false
  @spec query_spool(String.t(), map(), pos_integer()) ::
          {:ok, map()} | {:unavailable, String.t()}
  def query_spool(root, payload, timeout_ms) do
    id = Ecto.UUID.generate()
    request_dir = Path.join(root, "witness_requests")
    result_dir = Path.join(root, "witness_results")
    request_path = Path.join(request_dir, id <> ".json")
    result_path = Path.join(result_dir, id <> ".json")
    temporary = Path.join(request_dir, "." <> id <> ".new")
    envelope = %{"request_id" => id, "request" => payload}

    with true <- private_directory?(root),
         true <- private_directory?(request_dir) and private_directory?(result_dir),
         :ok <- publish_exclusive_arm(temporary, request_path, envelope) do
      await_spool_response(result_path, id, System.monotonic_time(:millisecond) + timeout_ms)
    else
      _ -> {:unavailable, "guest_witness_unavailable"}
    end
  rescue
    _ -> {:unavailable, "guest_witness_unavailable"}
  end

  @spec await_spool_response(String.t(), String.t(), integer()) ::
          {:ok, map()} | {:unavailable, String.t()}
  defp await_spool_response(path, id, deadline) do
    case File.lstat(path) do
      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          await_spool_response(path, id, deadline)
        else
          {:unavailable, "guest_witness_unavailable"}
        end

      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= 20_000 ->
        result =
          case read_private_object(path, 20_000) do
            {:ok, %{"request_id" => ^id, "response" => %{} = response} = record}
            when map_size(record) == 2 ->
              {:ok, response}

            _ ->
              {:unavailable, "guest_witness_unavailable"}
          end

        File.rm(path)
        result

      _ ->
        {:unavailable, "guest_witness_unavailable"}
    end
  end

  @spec sanitize(String.t(), term(), request()) :: result()
  def sanitize("identity", raw, _request) when is_map(raw) do
    keys = ~w(image_id memory_bytes minimum_disk_bytes state vcpu workspace_source_version)

    with true <- Enum.sort(Map.keys(raw)) == keys,
         true <- raw["state"] == "ok",
         true <- is_binary(raw["image_id"]) and String.starts_with?(raw["image_id"], "sha256:"),
         true <- digest?(String.replace_prefix(raw["image_id"], "sha256:", "")),
         true <- positive_number?(raw["minimum_disk_bytes"]),
         true <- positive_number?(raw["memory_bytes"]),
         true <- positive_number?(raw["vcpu"]),
         true <-
           is_nil(raw["workspace_source_version"]) or
             raw["workspace_source_version"] == 2 do
      {:ok, raw}
    else
      _ -> {:unavailable, "guest_witness_unavailable"}
    end
  end

  def sanitize("witness", raw, request) when is_map(raw) do
    keys =
      ~w(backend boot_challenge_sha256 boot_id execution_epoch generation guest_state image_manifest_sha256 overlay_bytes overlay_present overlay_sha256 placement_id qemu ready state)

    with true <- Enum.sort(Map.keys(raw)) == keys,
         true <- raw["state"] == "ok",
         true <- raw["placement_id"] == request["placement_id"],
         true <- raw["execution_epoch"] == request["execution_epoch"],
         true <- raw["generation"] == request["generation"],
         true <- raw["guest_state"] in ~w(running stopped),
         true <- is_boolean(raw["ready"]),
         true <- uuid_or_nil?(raw["boot_id"]),
         true <- digest?(raw["boot_challenge_sha256"]),
         true <- digest?(raw["image_manifest_sha256"]),
         true <- process?(raw["qemu"]) and process?(raw["backend"]),
         true <- is_boolean(raw["overlay_present"]),
         true <- nonnegative_or_nil?(raw["overlay_bytes"]),
         true <- digest_or_nil?(raw["overlay_sha256"]) do
      if coherent_witness?(raw), do: {:ok, raw}, else: {:unavailable, "guest_witness_unavailable"}
    else
      _ -> {:unavailable, "guest_witness_unavailable"}
    end
  end

  def sanitize("terminal_witness", raw, _request) when is_map(raw) do
    keys =
      ~w(births daemon_pid daemon_start_ticks deaths ledger_digests ring_total sessions state version viewer_total)

    with true <- Enum.sort(Map.keys(raw)) == keys,
         true <- raw["state"] == "ok" and raw["version"] == 1,
         true <- positive_number?(raw["daemon_pid"]),
         true <- nonnegative?(raw["daemon_start_ticks"]),
         true <- nonnegative?(raw["births"]) and nonnegative?(raw["deaths"]),
         true <- nonnegative?(raw["ring_total"]) and nonnegative?(raw["viewer_total"]),
         true <- is_list(raw["sessions"]) and length(raw["sessions"]) <= 64,
         true <- Enum.all?(raw["sessions"], &session?/1),
         true <- is_list(raw["ledger_digests"]) and length(raw["ledger_digests"]) <= 128,
         true <- Enum.all?(raw["ledger_digests"], &ledger_digest?/1) do
      {:ok, raw}
    else
      _ -> {:unavailable, "guest_witness_unavailable"}
    end
  end

  def sanitize("terminal_input_stall", raw, request) when is_map(raw) do
    keys = ~w(elapsed_ms in_progress pid session_id state version)

    with true <- Enum.sort(Map.keys(raw)) == keys,
         true <- raw["state"] == "ok" and raw["version"] == 1,
         true <- raw["session_id"] == String.to_integer(request["session_id"]),
         true <- positive_number?(raw["pid"]),
         true <- is_boolean(raw["in_progress"]),
         true <- nonnegative?(raw["elapsed_ms"]) do
      {:ok, raw}
    else
      _ -> {:unavailable, "guest_witness_unavailable"}
    end
  end

  def sanitize(_, _, _), do: {:unavailable, "guest_witness_unavailable"}

  @spec coherent_witness?(map()) :: boolean()
  defp coherent_witness?(%{"guest_state" => "running"} = raw) do
    is_map(raw["qemu"]) and is_map(raw["backend"]) and raw["overlay_present"] and
      (not raw["ready"] or uuid?(raw["boot_id"]))
  end

  defp coherent_witness?(%{"guest_state" => "stopped"} = raw) do
    is_nil(raw["qemu"]) and is_nil(raw["backend"]) and
      not raw["ready"] and is_nil(raw["boot_id"])
  end

  @spec session?(term()) :: boolean()
  defp session?(raw) when is_map(raw) do
    keys =
      ~w(alive deque_allocated pid proc_start_ticks ring_base ring_limit ring_tail session_id viewers)

    Enum.sort(Map.keys(raw)) == keys and positive_u63?(raw["session_id"]) and
      positive_number?(raw["pid"]) and nonnegative?(raw["proc_start_ticks"]) and
      is_boolean(raw["alive"]) and nonnegative?(raw["ring_base"]) and
      nonnegative?(raw["ring_tail"]) and nonnegative?(raw["ring_limit"]) and
      nonnegative?(raw["deque_allocated"]) and is_list(raw["viewers"]) and
      length(raw["viewers"]) <= 8 and Enum.all?(raw["viewers"], &viewer?/1)
  end

  defp session?(_), do: false

  @spec viewer?(term()) :: boolean()
  defp viewer?(%{"blocked_write" => blocked, "queue_bytes" => bytes} = raw),
    do:
      Enum.sort(Map.keys(raw)) == ~w(blocked_write queue_bytes) and is_boolean(blocked) and
        nonnegative?(bytes)

  defp viewer?(_), do: false

  @spec process?(term()) :: boolean()
  defp process?(nil), do: true

  defp process?(%{"pid" => pid, "start_ticks" => ticks} = raw),
    do:
      Enum.sort(Map.keys(raw)) == ~w(pid start_ticks) and positive_number?(pid) and
        positive_number?(ticks)

  defp process?(_), do: false

  @spec positive_number?(term()) :: boolean()
  defp positive_number?(n), do: is_integer(n) and n > 0 and n <= @max_integer

  @spec positive_u63?(term()) :: boolean()
  defp positive_u63?(n), do: is_integer(n) and n > 0 and n <= 9_223_372_036_854_775_807

  @spec nonnegative?(term()) :: boolean()
  defp nonnegative?(n), do: is_integer(n) and n >= 0 and n <= @max_unsigned

  @spec nonnegative_or_nil?(term()) :: boolean()
  defp nonnegative_or_nil?(nil), do: true
  defp nonnegative_or_nil?(n), do: nonnegative?(n)

  @spec uuid?(term()) :: boolean()
  defp uuid?(n), do: is_binary(n) and Regex.match?(@uuid, n)

  @spec uuid_or_nil?(term()) :: boolean()
  defp uuid_or_nil?(nil), do: true
  defp uuid_or_nil?(n), do: uuid?(n)

  @spec digest?(term()) :: boolean()
  defp digest?(n), do: is_binary(n) and Regex.match?(@digest, n)

  @spec ledger_digest?(term()) :: boolean()
  defp ledger_digest?(n), do: is_binary(n) and Regex.match?(@ledger_digest, n)

  @spec session_id?(term()) :: boolean()
  defp session_id?(n) when is_binary(n) do
    Regex.match?(~r/\A[1-9][0-9]{0,18}\z/, n) and
      String.to_integer(n) <= 9_223_372_036_854_775_807
  end

  defp session_id?(_), do: false

  @spec digest_or_nil?(term()) :: boolean()
  defp digest_or_nil?(nil), do: true
  defp digest_or_nil?(n), do: digest?(n)

  @spec envelope(request(), String.t(), String.t(), map()) :: map()
  defp envelope(request, operation, status, detail) do
    Map.merge(
      %{
        "version" => 1,
        "request_id" => request["request_id"],
        "operation" => operation,
        "status" => status
      },
      Enum.into(detail, %{}, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end
end
