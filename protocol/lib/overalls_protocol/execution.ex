defmodule OverallsProtocol.Execution do
  @moduledoc "Placement-bound executable commands and physical outcomes in v4 control documents."
  alias OverallsProtocol.{GitIdentity, ImageManifest, ProfilePolicy, VMShape, WorkspaceSource}
  @maximum 9_223_372_036_854_775_807
  @type command :: %{
          optional(:resize_from) => map(),
          optional(:resize_id) => OverallsProtocol.uuid(),
          optional(:clone_id) => OverallsProtocol.uuid(),
          optional(:workspace_source) => WorkspaceSource.t(),
          optional(:git_identity) => GitIdentity.t(),
          id: OverallsProtocol.uuid(),
          owner_id: OverallsProtocol.uuid(),
          vm_id: OverallsProtocol.uuid(),
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          host_id: OverallsProtocol.uuid(),
          pool_id: OverallsProtocol.uuid(),
          generation: pos_integer(),
          kind: :provision | :start | :stop | :delete | :resize | :pause | :resume,
          architecture: :x86_64,
          profile: :customer | :standard | :oss | :inception,
          vcpu: pos_integer(),
          memory_bytes: pos_integer(),
          disk_bytes: pos_integer(),
          image_id: String.t(),
          slot: pos_integer()
        }
  @type outcome :: %{
          optional(:guest_ready) => true,
          optional(:checkpoint) => OverallsProtocol.Checkpoint.t(),
          id: OverallsProtocol.uuid(),
          vm_id: OverallsProtocol.uuid(),
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          operation_id: OverallsProtocol.uuid(),
          generation: pos_integer(),
          sequence: pos_integer(),
          state: :running | :stopped | :paused | :deleted | :failed | :unknown,
          compute_empty: boolean(),
          disk_present: boolean(),
          cleanup_complete: boolean(),
          reason:
            :none | :execution_failed | :crashed | :cleanup_failed | :identity_mismatch | :unknown
        }
  @type session :: %{session_id: OverallsProtocol.uuid(), machine_id: String.t()}
  @type exchange :: %{
          session_id: OverallsProtocol.uuid(),
          epoch: pos_integer(),
          report: OverallsProtocol.report() | nil,
          acknowledgements: [OverallsProtocol.uuid()],
          outcomes: [outcome()]
        }
  @type failure :: {:error, :invalid_message | :unsupported_version | :message_too_large}

  # @cc [owner:ghuntley,label:security;protocol] v4-machine-bound-session
  # session/1 MUST require explicit version 4, a canonical session UUID and a sha256 machine
  # identity; a v1 receipt session must never be accepted as execution authority.
  @spec session(term()) :: {:ok, session()} | failure()
  def session(%{"version" => 4, "session_id" => id, "machine_id" => machine} = value)
      when map_size(value) == 3 do
    if OverallsProtocol.uuid?(id) and machine_id?(machine),
      do: {:ok, %{session_id: id, machine_id: machine}},
      else: {:error, :invalid_message}
  end

  def session(value), do: invalid(value)

  @spec exchange(term()) :: {:ok, exchange()} | failure()
  def exchange(
        %{
          "version" => 4,
          "session_id" => id,
          "epoch" => epoch,
          "report" => report,
          "acknowledgements" => acks,
          "outcomes" => outcomes
        } = value
      )
      when map_size(value) == 6 do
    with true <- OverallsProtocol.uuid?(id) and positive?(epoch),
         true <-
           is_list(acks) and length(acks) <= 16 and Enum.all?(acks, &OverallsProtocol.uuid?/1),
         true <- Enum.uniq(acks) == acks,
         {:ok, report} <- OverallsProtocol.report(report),
         {:ok, outcomes} <- outcomes(outcomes) do
      {:ok,
       %{session_id: id, epoch: epoch, report: report, acknowledgements: acks, outcomes: outcomes}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def exchange(value), do: invalid(value)

  # @cc [owner:ghuntley,label:protocol] executable-command-batch-limit
  # commands/1 MUST accept at most 16 executable commands with distinct operation IDs; one invalid
  # item rejects the entire batch.
  @spec commands(term()) :: {:ok, [command()]} | failure()
  def commands(values), do: collection(values, &command/1, :id)
  # @cc [owner:ghuntley,label:protocol] physical-outcome-batch-limit
  # outcomes/1 MUST accept at most 16 outcomes with distinct event IDs and at most one outcome per
  # placement; one invalid item rejects the entire batch.
  @spec outcomes(term()) :: {:ok, [outcome()]} | failure()
  def outcomes(values), do: collection(values, &outcome/1, :placement_id)

  # @cc [owner:ghuntley,label:protocol] executable-image-address-and-shape
  # command/1 MUST reject executable intent without an immutable image digest, an allocatable
  # profile slot and VMShape-aligned resource sizes. Ordinary commands have exactly
  # 15 fields plus the required owning-user metadata;
  # resize adds its source shape and stable request ID, and resize starts
  # add that request ID to require guest readiness. Clone starts add clone_id for readiness.
  # Provision and start may add workspace_source and git_identity metadata. Other fields MUST be rejected.
  @spec command(term()) :: {:ok, command()} | failure()
  # @cc [owner:ghuntley,label:security] command-owner-is-validated-metadata
  # Every command MUST carry owner metadata as a canonical UUID that survives
  # round trips; a command without `owner_id` is rejected. The owner MUST NOT
  # relax placement/epoch validation or grant execution authority.
  def command(%{"owner_id" => owner} = value) do
    with true <- OverallsProtocol.uuid?(owner),
         {:ok, command} <- placement_command(Map.delete(value, "owner_id")) do
      {:ok, Map.put(command, :owner_id, owner)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def command(_value), do: {:error, :invalid_message}

  @doc """
  Validates the placement and workload shape of a command without owner
  metadata. Only portable transfer descriptors use it to check the workload
  they bind; its result is never executable intent (see command/1).
  """
  @spec placement_command(term()) :: {:ok, map()} | failure()

  # @cc [owner:ghuntley,label:security;protocol] command-git-attribution-metadata
  # Optional git_identity MUST be closed validated attribution on provision/start
  # only. Its absence MUST remain valid and MUST NOT imply a default identity;
  # attribution MUST NOT relax placement, owner or execution validation.
  def placement_command(%{"git_identity" => identity} = value) do
    with {:ok, identity} <- GitIdentity.decode(identity),
         {:ok, command} <- placement_command(Map.delete(value, "git_identity")),
         true <- command.kind in [:provision, :start] do
      {:ok, Map.put(command, :git_identity, identity)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] command-workspace-source-reference
  # An optional workspace_source MUST be the closed versioned public repository reference, only on
  # provision or start commands, and only for profiles allowed egress. It is inert data for
  # the guest to clone: it MUST NOT relax placement/epoch validation or select host paths.
  def placement_command(%{"workspace_source" => source} = value) do
    with {:ok, source} <- WorkspaceSource.decode(source),
         {:ok, command} <- placement_command(Map.delete(value, "workspace_source")),
         true <- command.kind in [:provision, :start, :resume],
         true <- ProfilePolicy.allows?(command.profile, :egress) do
      {:ok, Map.put(command, :workspace_source, source)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def placement_command(
        %{"kind" => "resize", "resize_from" => source, "resize_id" => resize_id} = value
      )
      when map_size(value) == 17 do
    with {:ok, target} <- shaped_command(Map.drop(value, ["resize_from", "resize_id"])),
         true <- OverallsProtocol.uuid?(resize_id),
         true <- OverallsProtocol.Resize.valid_transition?(source, target) do
      {:ok, Map.merge(target, %{resize_from: source, resize_id: resize_id})}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def placement_command(%{"kind" => "start", "resize_id" => id} = value)
      when map_size(value) == 16 do
    with true <- OverallsProtocol.uuid?(id),
         {:ok, command} <- shaped_command(Map.delete(value, "resize_id")) do
      {:ok, Map.put(command, :resize_id, id)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def placement_command(%{"kind" => "start", "clone_id" => id} = value)
      when map_size(value) == 16 do
    with true <- OverallsProtocol.uuid?(id),
         {:ok, command} <- shaped_command(Map.delete(value, "clone_id")),
         do: {:ok, Map.put(command, :clone_id, id)},
         else: (_ -> {:error, :invalid_message})
  end

  def placement_command(%{"kind" => "resume", "checkpoint" => value} = wire) do
    with {:ok, checkpoint} <- OverallsProtocol.Checkpoint.decode(value),
         {:ok, command} <- shaped_command(Map.delete(wire, "checkpoint")),
         true <- command.memory_bytes == checkpoint.memory_bytes do
      {:ok, Map.put(command, :checkpoint, checkpoint)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def placement_command(%{"kind" => "resume"}), do: {:error, :invalid_message}
  def placement_command(%{"kind" => "resize"}), do: {:error, :invalid_message}
  def placement_command(value), do: shaped_command(value)

  defp shaped_command(%{"image_id" => image, "slot" => slot} = value)
       when map_size(value) == 15 do
    with {:ok, base} <- base_command(Map.drop(value, ["image_id", "slot"])),
         true <- ImageManifest.id?(image) and is_integer(slot) and slot in 2..65534,
         true <- VMShape.valid?(base.vcpu, base.memory_bytes, base.disk_bytes) do
      {:ok, Map.merge(base, %{image_id: image, slot: slot})}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp shaped_command(_), do: {:error, :invalid_message}

  defp base_command(
         %{
           "id" => id,
           "vm_id" => vm,
           "placement_id" => placement,
           "execution_epoch" => execution_epoch,
           "host_id" => host,
           "pool_id" => pool,
           "generation" => generation,
           "kind" => kind,
           "architecture" => "x86_64",
           "profile" => profile,
           "vcpu" => cpu,
           "memory_bytes" => memory,
           "disk_bytes" => disk
         } = command
       )
       when map_size(command) == 13 do
    with true <- Enum.all?([id, vm, placement, host, pool], &OverallsProtocol.uuid?/1),
         true <- positive?(execution_epoch),
         true <- positive?(generation) and is_integer(cpu) and cpu in 1..32,
         true <- is_integer(memory) and memory in 536_870_912..274_877_906_944,
         true <- VMShape.valid?(cpu, memory, disk),
         {:ok, kind} <-
           enum(kind, [:provision, :start, :stop, :delete, :resize, :pause, :resume]),
         {:ok, profile} <-
           enum(profile, [:customer, :standard, :oss, :inception]) do
      {:ok,
       %{
         id: id,
         vm_id: vm,
         placement_id: placement,
         execution_epoch: execution_epoch,
         host_id: host,
         pool_id: pool,
         generation: generation,
         kind: kind,
         architecture: :x86_64,
         profile: profile,
         vcpu: cpu,
         memory_bytes: memory,
         disk_bytes: disk
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp base_command(_), do: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:recovery] physical-outcome-coherence
  # outcome/1 MUST reject contradictory physical facts: deleted requires empty compute, absent
  # disk and completed cleanup; failed requires empty compute; unknown may never claim completed
  # cleanup. All identities, generations and sequences must validate before facts reach lifecycle
  # accounting.
  @spec outcome(term()) :: {:ok, outcome()} | failure()
  # @cc [owner:ghuntley,label:protocol;recovery] guest-ready-is-an-exact-physical-fact
  # guest_ready MUST be true only on a coherent running outcome. Its absence is
  # unknown, never readiness. Consumers MUST additionally bind provision/start
  # operation identity; the fact grants no independent execution authority.
  def outcome(%{"checkpoint" => value, "state" => state} = wire)
      when state in ["paused", "running"] do
    with {:ok, checkpoint} <- OverallsProtocol.Checkpoint.decode(value),
         {:ok, outcome} <- checkpoint_outcome(Map.delete(wire, "checkpoint")) do
      {:ok, Map.put(outcome, :checkpoint, checkpoint)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def outcome(%{"checkpoint" => _}), do: {:error, :invalid_message}
  def outcome(%{"state" => "paused"}), do: {:error, :invalid_message}

  def outcome(%{"guest_ready" => true, "state" => "running"} = value) do
    with {:ok, outcome} <- outcome(Map.delete(value, "guest_ready")),
         do: {:ok, Map.put(outcome, :guest_ready, true)}
  end

  def outcome(%{"guest_ready" => _}), do: {:error, :invalid_message}

  def outcome(%{"applied_sizes" => sizes, "state" => "stopped", "disk_present" => true} = value)
      when map_size(value) == 13 do
    with true <- OverallsProtocol.Resize.valid_sizes?(sizes),
         {:ok, outcome} <- outcome(Map.delete(value, "applied_sizes")) do
      {:ok, Map.put(outcome, :applied_sizes, sizes)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def outcome(value), do: decode_outcome(value)

  defp decode_outcome(
         %{
           "id" => id,
           "vm_id" => vm,
           "placement_id" => placement,
           "execution_epoch" => execution_epoch,
           "operation_id" => operation,
           "generation" => generation,
           "sequence" => sequence,
           "state" => state,
           "compute_empty" => empty,
           "disk_present" => disk,
           "cleanup_complete" => cleanup,
           "reason" => reason
         } = value
       )
       when map_size(value) == 12 do
    with true <- Enum.all?([id, vm, placement, operation], &OverallsProtocol.uuid?/1),
         true <- positive?(execution_epoch),
         true <- positive?(generation) and positive?(sequence),
         true <- is_boolean(empty) and is_boolean(disk) and is_boolean(cleanup),
         {:ok, state} <- enum(state, [:running, :stopped, :paused, :deleted, :failed, :unknown]),
         {:ok, reason} <-
           enum(reason, [
             :none,
             :execution_failed,
             :crashed,
             :cleanup_failed,
             :identity_mismatch,
             :unknown
           ]),
         true <- coherent?(state, empty, disk, cleanup, reason) do
      {:ok,
       %{
         id: id,
         vm_id: vm,
         placement_id: placement,
         execution_epoch: execution_epoch,
         operation_id: operation,
         generation: generation,
         sequence: sequence,
         state: state,
         compute_empty: empty,
         disk_present: disk,
         cleanup_complete: cleanup,
         reason: reason
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp decode_outcome(_), do: {:error, :invalid_message}

  defp checkpoint_outcome(%{"guest_ready" => true, "state" => "running"} = wire) do
    with {:ok, outcome} <- decode_outcome(Map.delete(wire, "guest_ready")),
         do: {:ok, Map.put(outcome, :guest_ready, true)}
  end

  defp checkpoint_outcome(wire), do: decode_outcome(wire)

  @spec encode_command(command()) :: map()
  def encode_command(%{git_identity: identity} = command) do
    command
    |> Map.delete(:git_identity)
    |> encode_command()
    |> Map.put("git_identity", GitIdentity.encode(identity))
  end

  def encode_command(%{workspace_source: source} = command) do
    command
    |> Map.delete(:workspace_source)
    |> encode_command()
    |> Map.put("workspace_source", WorkspaceSource.encode(source))
  end

  def encode_command(command) do
    Map.new(command, fn {key, value} ->
      {Atom.to_string(key), if(is_atom(value), do: Atom.to_string(value), else: value)}
    end)
  end

  @spec encode_outcome(outcome()) :: map()
  def encode_outcome(%{checkpoint: checkpoint} = outcome) do
    outcome
    |> Map.delete(:checkpoint)
    |> encode_outcome()
    |> Map.put("checkpoint", OverallsProtocol.Checkpoint.encode(checkpoint))
  end

  def encode_outcome(outcome) do
    Map.new(outcome, fn {key, value} ->
      {Atom.to_string(key),
       if(is_atom(value) and value not in [true, false, nil],
         do: Atom.to_string(value),
         else: value
       )}
    end)
  end

  @spec machine_id?(term()) :: boolean()
  def machine_id?(value) when is_binary(value),
    do: Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, value)

  def machine_id?(_), do: false

  defp coherent?(:running, false, true, false, :none), do: true
  defp coherent?(:paused, true, true, false, :none), do: true
  defp coherent?(:stopped, true, _disk, false, :none), do: true
  defp coherent?(:deleted, true, false, true, :none), do: true

  defp coherent?(:failed, empty, _disk, false, reason),
    do: empty and reason in [:execution_failed, :crashed]

  defp coherent?(:unknown, _empty, _disk, false, reason),
    do: reason in [:cleanup_failed, :identity_mismatch, :unknown]

  defp coherent?(_, _, _, _, _), do: false

  defp collection(values, decoder, identity) when is_list(values) and length(values) <= 16 do
    result =
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case decoder.(value) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          _ -> {:halt, {:error, :invalid_message}}
        end
      end)

    with {:ok, values} <- result,
         ids = Enum.map(values, &Map.fetch!(&1, identity)),
         true <- Enum.uniq(ids) == ids,
         true <- length(Enum.uniq_by(values, & &1.id)) == length(values),
         do: {:ok, Enum.reverse(values)},
         else: (_ -> {:error, :invalid_message})
  end

  defp collection(_, _, _), do: {:error, :invalid_message}
  defp positive?(value), do: is_integer(value) and value in 1..@maximum

  defp enum(value, atoms) do
    case Enum.find(atoms, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp invalid(%{"version" => version}) when version != 4, do: {:error, :unsupported_version}
  defp invalid(_), do: {:error, :invalid_message}
end
