defmodule Lilly.Host.ZFS do
  @moduledoc "Read-only native ZFS identity and accounting. This module does not establish VM ownership."
  require Lilly.Events
  alias OverallsProtocol.Storage
  alias Lilly.Host.{Command, Pool}

  @maximum 9_223_372_036_854_775_807
  @properties ~w(name type guid mountpoint mounted compression reservation refreservation dedup sync origin used available logicalused quota compressratio usedbychildren usedbydataset usedbyrefreservation usedbysnapshots refquota readonly canmount)
  @integers ~w(reservation refreservation used available logicalused quota usedbychildren usedbydataset usedbyrefreservation usedbysnapshots refquota)
  @usage_properties ~w(used available logicalused compressratio usedbychildren usedbydataset usedbysnapshots)
  @snapshot_absent @properties -- ~w(name type guid used compressratio)
  @type extent :: %{
          backing_device: String.t(),
          start_sector: non_neg_integer(),
          sectors: pos_integer()
        }
  @type t :: %{
          path: Path.t(),
          filesystem_id: String.t(),
          storage: Storage.identity(),
          extents: [extent()]
        }
  @type dataset :: %{String.t() => String.t() | non_neg_integer() | float()}
  @type tree :: %{String.t() => dataset()}
  @type snapshots :: %{
          String.t() => %{dataset_guid: String.t(), snapshot_guid: String.t()}
        }
  @typep observation_stage ::
           :identity_before
           | :datasets_before
           | :datasets_after
           | :property_stability
           | :identity_after
           | :accounting_before
           | :accounting_after
           | :resample_properties
           | :accounting_exhausted
  @typep observation_reason :: :unconfirmed | :changed | :rejected | :exhausted
  @typep diagnostic_placement :: OverallsProtocol.uuid() | nil
  @typep identity_diagnostic ::
           nil | {diagnostic_placement(), :identity_before | :identity_after}
  @typep identity_probe_reason ::
           :canonical_path
           | :dataset_mount
           | :parent_read
           | :parent_shape
           | :parent_policy
           | :parent_accounting
           | :root_read
           | :root_shape
           | :root_compression
           | :pool_status
           | :pool_identity
           | :storage_identity
           | :backing_extents
  @maximum_rows 16_385

  # @cc [owner:ghuntley,label:security;capacity] zfs-canonical-mount-and-backing
  # inspect_path/1 MUST bind the actual dataset mount root, pool GUID and dataset GUID to
  # plain block-device extents. Mount aliases, subdirectories, file vdevs, stacked devices and
  # unsupported topology MUST fail. A successful read does not enroll or claim the pool.
  @spec inspect_path(Path.t()) :: {:ok, t()} | {:error, atom()}
  def inspect_path(path), do: inspect_path(path, &policy?/1)

  # @cc [owner:ghuntley,label:recovery;security] staging-identity-grants-no-credit
  # This probe MUST bind the canonical parent, GUIDs, safe policy and healthy
  # backing extents to the supplied identity. Only usage decomposition may be
  # ignored; numeric bounds and all other parent policy checks remain mandatory.
  # Success MUST grant no capacity, ownership or execution authority. Its caller
  # must independently verify active local import ownership before deferring.
  @spec staging_identity?(t()) :: boolean()
  def staging_identity?(identity),
    do: inspect_path(identity.path, &policy_shape?(&1, "yes", false, :active)) == {:ok, identity}

  # @cc [owner:ghuntley,label:observability;security;capacity] identity-probe-diagnostics-preserve-proof
  # Diagnostic identity probes MUST retain every canonical mount, policy,
  # accounting, GUID and healthy backing guard and the unsupported_zfs_pool result.
  # Only a validated placement, before/after stage and fixed rejection atom may
  # be emitted. Ordinary inspection MUST stay quiet; parent_accounting identifies
  # a usage decomposition rejection only after every parent policy-shape check passes.
  @spec inspect_path(Path.t(), (dataset() -> boolean()), identity_diagnostic()) ::
          {:ok, t()} | {:error, :unsupported_zfs_pool}
  defp inspect_path(path, parent_policy?, diagnostic \\ nil) do
    with {:canonical_path, {:ok, canonical}} <- {:canonical_path, canonical(path)},
         {:canonical_path, true} <- {:canonical_path, canonical == path},
         {:dataset_mount, {:ok, dataset}} <- {:dataset_mount, mounted_dataset(path)},
         {:parent_read, {:ok, entries}} <- {:parent_read, read_datasets(dataset, false)},
         {:parent_shape, %{^dataset => parent}} when map_size(entries) == 1 <-
           {:parent_shape, entries},
         {:parent_policy, :ok} <- {:parent_policy, probe_parent_policy(parent, parent_policy?)},
         {:parent_policy, true} <- {:parent_policy, parent["mountpoint"] == path},
         zpool = dataset |> String.split("/") |> hd(),
         {:root_read, {:ok, root_entries}} <- {:root_read, read_datasets(zpool, false)},
         {:root_shape, %{^zpool => root}} when map_size(root_entries) == 1 <-
           {:root_shape, root_entries},
         {:root_compression, true} <- {:root_compression, root["compression"] == "lz4"},
         # OpenZFS 2.4 looks up JSON metadata by the displayed vdev name. -L
         # can turn a persisted /dev/disk alias into a name that lookup cannot
         # find, omitting mandatory identity/health fields. Preserve the stored
         # paths here; extents/1 independently canonicalizes and verifies them.
         {:pool_status, {:ok, output}} <-
           {:pool_status, Command.run(:zpool_status, ["-jPp", zpool])},
         {:pool_identity, {:ok, pool_guid, paths}} <-
           {:pool_identity, parse_status(output, zpool)},
         storage = %{
           backend: :zfs,
           dataset: dataset,
           dataset_guid: parent["guid"],
           zpool_guid: pool_guid
         },
         {:storage_identity, true} <- {:storage_identity, Storage.valid_identity?(storage)},
         {:backing_extents, {:ok, extents}} <- {:backing_extents, extents(paths)} do
      {:ok,
       %{
         path: path,
         filesystem_id: Storage.filesystem_id(storage),
         storage: storage,
         extents: extents
       }}
    else
      {:parent_policy, :parent_accounting} ->
        identity_probe_failed(diagnostic, :parent_accounting)
        {:error, :unsupported_zfs_pool}

      {reason, _} ->
        identity_probe_failed(diagnostic, reason)
        {:error, :unsupported_zfs_pool}
    end
  end

  @spec probe_parent_policy(dataset(), (dataset() -> boolean())) ::
          :ok | :parent_policy | :parent_accounting
  defp probe_parent_policy(parent, parent_policy?) do
    cond do
      parent_policy?.(parent) -> :ok
      policy_shape?(parent, "yes", false, :active) -> :parent_accounting
      true -> :parent_policy
    end
  end

  @spec identity_probe_failed(identity_diagnostic(), identity_probe_reason()) :: :ok
  defp identity_probe_failed(nil, _reason), do: :ok
  defp identity_probe_failed({nil, _stage}, _reason), do: :ok

  defp identity_probe_failed({placement_id, stage}, reason) do
    Lilly.Events.emit("vm.dataset_identity_probe_failed",
      placement_id: placement_id,
      stage: stage,
      reason: reason
    )
  end

  # @cc [owner:ghuntley,label:capacity] zfs-stable-accounting-is-not-ownership
  # observe/2 MUST withhold identity and non-usage property changes, and
  # check physical decomposition and quota bounds. Returned child physical usage MUST NOT be
  # used as allocation credit until a caller separately verifies durable VM ownership.
  # Two equal reads are observations, not a reservation or a freeze of concurrent guest writes.
  # A change confined to usage counters MUST use at most three complete attempts, 25 ms apart,
  # only when both trees satisfy accounting and retain identical dataset identities/policies
  # and verified backing identity. If usage keeps moving, the latest coherent tree MUST be
  # the observation (ADR-0163); genuine storage_busy MUST remain a refusal, not a resample.
  # Snapshot expectations MUST come from independently verified host-local ownership;
  # native names/tags alone or peer descriptors MUST NOT supply them.
  # Incoherent accounting MAY use at most three complete attempts with the same
  # non-usage properties. Identity/policy drift and exhaustion MUST fail.
  @spec observe(t(), snapshots()) :: {:ok, map()} | {:error, atom()}
  def observe(identity, snapshots \\ %{}),
    do: observe_with_diagnostics(identity, snapshots, nil, :exact)

  # @cc [owner:ghuntley,label:recovery;capacity] identity-observation-grants-no-credit
  # Identity observations MUST perform the same two reads, identity/backing checks,
  # non-usage property stability, accounting validation and bounded resampling as
  # observe/2, but MAY tolerate a change confined to usage counters between the
  # reads, returning the first sample. Pool-wide counters such as `available`
  # move with any write, so they cannot fence identity. Callers MUST use only
  # identity, ownership, snapshot and policy fields; usage values from this
  # result MUST NOT grant capacity credit, admission or allocation evidence.
  @spec observe_identity(t(), snapshots()) :: {:ok, map()} | {:error, atom()}
  def observe_identity(identity, snapshots \\ %{}),
    do: observe_with_diagnostics(identity, snapshots, nil, :identity)

  # @cc [owner:ghuntley,label:observability;security;capacity] readiness-observation-diagnostics-only
  # Readiness diagnostics MUST use the same whole-pool reads, guards, accounting
  # and three-attempt bound as observe/2, or observe_identity/2 when the caller
  # passes `:identity` usage. Only a validated placement UUID
  # and fixed stage/reason atoms may be emitted; properties, paths, native output
  # and bindings MUST NOT leave this boundary. Rejected samples may be reported
  # before a later sample recovers; coherent usage-only busy samples and ordinary
  # admission observations MUST stay quiet. Diagnostics grant no ownership or credit.
  # `staged` names owned, finished, unadopted import children; accounting
  # validates them under receive policy (read-only, noauto, unmounted) with
  # their journal-fixed snapshots instead of refusing the pool.
  # `usage` follows observe/2 (`:exact`) or observe_identity/2 (`:identity`),
  # including the identity rule that usage values grant no credit.
  @spec observe_for_readiness(
          t(),
          snapshots(),
          OverallsProtocol.uuid(),
          MapSet.t(String.t()),
          :exact | :identity
        ) ::
          {:ok, map()} | {:error, atom()}
  def observe_for_readiness(
        identity,
        snapshots,
        placement_id,
        staged \\ MapSet.new(),
        usage \\ :exact
      )
      when usage in [:exact, :identity] do
    diagnostic = if OverallsProtocol.uuid?(placement_id), do: placement_id, else: nil
    observe_with_diagnostics(identity, snapshots, diagnostic, usage, staged)
  end

  @spec observe_with_diagnostics(
          t(),
          snapshots(),
          diagnostic_placement(),
          :exact | :identity,
          MapSet.t(String.t())
        ) ::
          {:ok, map()} | {:error, atom()}
  defp observe_with_diagnostics(identity, snapshots, diagnostic, usage, staged \\ MapSet.new()) do
    resample_observation(
      fn -> observe_once(identity, snapshots, diagnostic, usage, staged) end,
      3,
      nil,
      diagnostic
    )
  end

  # @cc [owner:ghuntley,label:recovery;capacity] zfs-bounded-resampling-no-credit
  # Resampling MUST perform at most three complete attempts and never reuse a
  # rejected result or grant credit on accounting exhaustion. Non-usage
  # properties MUST remain identical across attempts. Changed properties,
  # identity-read failures and storage_busy MUST not retry. A sample whose two
  # reads both pass accounting and differ only in usage counters is retried the
  # same way and, when the counters keep moving, the latest coherent tree is
  # the observation (ADR-0163): ordinary guest writes never withhold capacity.
  @doc false
  @spec resample_observation((-> {:sample, tree(),
                                  :retry
                                  | {:retry_usage, map()}
                                  | {:ok, map()}
                                  | {:error, atom()}}
                                 | {:error, atom()})) ::
          {:ok, map()} | {:error, atom()}
  def resample_observation(observe), do: resample_observation(observe, 3, nil, nil)

  defp resample_observation(observe, attempts, baseline, diagnostic) do
    case observe.() do
      {:sample, binding, result} when is_nil(baseline) or binding == baseline ->
        case result do
          :retry when attempts > 1 ->
            Process.sleep(25)
            resample_observation(observe, attempts - 1, binding, diagnostic)

          :retry ->
            observation_failed(diagnostic, :accounting_exhausted, :exhausted)
            {:error, :incoherent_zfs_observation}

          {:retry_usage, _latest} when attempts > 1 ->
            Process.sleep(25)
            resample_observation(observe, attempts - 1, binding, diagnostic)

          {:retry_usage, latest} ->
            {:ok, latest}

          result ->
            result
        end

      {:sample, _, _} ->
        observation_failed(diagnostic, :resample_properties, :changed)
        {:error, :incoherent_zfs_observation}

      result ->
        result
    end
  end

  defp observe_once(identity, snapshots, diagnostic, usage, staged) do
    with {:ok, ^identity} <-
           observation_identity(
             inspect_path(identity.path, &policy?/1, {diagnostic, :identity_before}),
             identity,
             diagnostic,
             :identity_before
           ),
         {:ok, before} <-
           observation_result(
             read_datasets(identity.storage.dataset, true),
             diagnostic,
             :datasets_before,
             :unconfirmed
           ),
         {:ok, after_read} <-
           observation_result(
             read_datasets(identity.storage.dataset, true),
             diagnostic,
             :datasets_after,
             :unconfirmed
           ),
         true <-
           observation_result(
             stable_properties(before) == stable_properties(after_read),
             diagnostic,
             :property_stability,
             :changed
           ),
         {:ok, ^identity} <-
           observation_identity(
             inspect_path(identity.path, &policy?/1, {diagnostic, :identity_after}),
             identity,
             diagnostic,
             :identity_after
           ) do
      result =
        decide_sample(
          before,
          after_read,
          accounting_result(
            classify_accounting(before, identity, snapshots, staged),
            diagnostic,
            :accounting_before
          ),
          accounting_result(
            classify_accounting(after_read, identity, snapshots, staged),
            diagnostic,
            :accounting_after
          ),
          usage
        )

      {:sample, stable_properties(before), result}
    else
      _ -> {:error, :incoherent_zfs_observation}
    end
  end

  @spec observation_identity(value, t(), diagnostic_placement(), observation_stage()) :: value
        when value: term()
  defp observation_identity(result, identity, diagnostic, stage) do
    case result do
      {:ok, ^identity} -> :ok
      {:ok, _} -> observation_failed(diagnostic, stage, :changed)
      _ -> observation_failed(diagnostic, stage, :unconfirmed)
    end

    result
  end

  @spec observation_result(
          value,
          diagnostic_placement(),
          observation_stage(),
          observation_reason()
        ) :: value
        when value: term()
  defp observation_result({:ok, _} = result, _diagnostic, _stage, _reason), do: result
  defp observation_result(true, _diagnostic, _stage, _reason), do: true

  defp observation_result(result, diagnostic, stage, reason) do
    observation_failed(diagnostic, stage, reason)
    result
  end

  # A rejected accounting sample reports which check failed (closed atoms).
  @spec accounting_result(
          {:ok, map()} | {:error, accounting_rejection()},
          diagnostic_placement(),
          observation_stage()
        ) :: {:ok, map()} | :error
  defp accounting_result({:ok, _} = result, _diagnostic, _stage), do: result

  defp accounting_result({:error, reason}, diagnostic, stage) do
    observation_failed(diagnostic, stage, reason)
    :error
  end

  @spec observation_failed(
          diagnostic_placement(),
          observation_stage(),
          observation_reason() | accounting_rejection()
        ) ::
          :ok
  defp observation_failed(nil, _stage, _reason), do: :ok

  defp observation_failed(placement_id, stage, reason) do
    Lilly.Events.emit("vm.dataset_observation_failed",
      placement_id: placement_id,
      stage: stage,
      reason: reason
    )
  end

  @doc false
  @spec stable_properties(tree()) :: tree()
  def stable_properties(tree),
    do: Map.new(tree, fn {name, row} -> {name, Map.drop(row, @usage_properties)} end)

  # Decide one complete sample whose non-usage properties were already proven
  # stable. Both trees must pass accounting; an exact observation whose usage
  # counters moved between the reads asks for a bounded resample carrying the
  # later coherent tree, identity observations take the first.
  @doc false
  @spec decide_sample(
          tree(),
          tree(),
          {:ok, map()} | :error,
          {:ok, map()} | :error,
          :exact | :identity
        ) :: {:ok, map()} | {:retry_usage, map()} | :retry
  def decide_sample(before, after_read, {:ok, result}, {:ok, latest}, usage) do
    if before == after_read or usage == :identity,
      do: {:ok, result},
      else: {:retry_usage, latest}
  end

  def decide_sample(_before, _after_read, _accounting_before, _accounting_after, _usage),
    do: :retry

  # @cc [owner:ghuntley,label:recovery;security] unmounted-child-is-not-capacity
  # child_mount_state/3 MUST verify the expected child GUID, canonical path, safe policy,
  # absence of descendants and unchanged parent/backing identity. It may accept an unmounted
  # child only as a deletion-recovery fact; it MUST NOT return capacity or allocation credit.
  @spec child_mount_state(t(), String.t(), String.t()) ::
          {:ok, :mounted | :unmounted} | {:error, :zfs_child_unconfirmed}
  def child_mount_state(identity, name, guid) do
    with {:ok, ^identity} <- inspect_path(identity.path),
         {:ok, before} <- read_datasets(name, true),
         {:ok, after_read} <- read_datasets(name, true),
         true <- stable_properties(before) == stable_properties(after_read),
         true <-
           Enum.all?([before, after_read], fn entries ->
             case entries do
               %{^name => row} when map_size(entries) == 1 ->
                 row["name"] == name and row["guid"] == guid and
                   row["mounted"] in ["yes", "no"] and policy?(row, row["mounted"]) and
                   child?({name, row}, identity)

               _ ->
                 false
             end
           end),
         {:ok, ^identity} <- inspect_path(identity.path) do
      {:ok, if(before[name]["mounted"] == "yes", do: :mounted, else: :unmounted)}
    else
      _ -> {:error, :zfs_child_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security] snapshot-source-policy-without-allocation-credit
  # transfer_child/4 MUST match the unchanged pool and child GUID, canonical mounted
  # policy and exact expected snapshot set in two reads. Unknown descendants and
  # inconsistent decomposition MUST fail. This check grants no allocation or stop proof.
  @spec transfer_child(t(), String.t(), String.t(), snapshots()) :: :ok | {:error, atom()}
  def transfer_child(identity, name, guid, snapshots) do
    with {:ok, ^identity} <- inspect_path(identity.path),
         {:ok, before} <- read_datasets(name, true),
         {:ok, after_read} <- read_datasets(name, true),
         true <- stable_properties(before) == stable_properties(after_read),
         true <-
           Enum.all?([before, after_read], &transfer_tree?(&1, identity, name, guid, snapshots)),
         {:ok, ^identity} <- inspect_path(identity.path) do
      :ok
    else
      _ -> {:error, :zfs_snapshot_source_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security] received-tree-is-not-an-executable-disk
  # receive_child/4 MUST verify exact filesystem/snapshot GUIDs, canonical path,
  # unmounted read-only noauto policy and local exec/setuid/devices=off settings.
  # A resume token, mount alias, extra descendant or changed backing identity MUST
  # fail. Callers hold the pool lock and separately prove stream quiescence and
  # local import ownership. Success grants neither allocation nor launch authority.
  @spec receive_child(t(), String.t(), String.t(), snapshots()) :: :ok | {:error, atom()}
  def receive_child(identity, name, guid, snapshots) do
    with {:ok, ^identity} <- inspect_path(identity.path),
         :ok <- receive_properties(name),
         true <- unmounted_child?(identity, name),
         {:ok, before} <- read_datasets(name, true),
         {:ok, after_read} <- read_datasets(name, true),
         true <- stable_properties(before) == stable_properties(after_read),
         true <-
           Enum.all?(
             [before, after_read],
             &transfer_tree?(&1, identity, name, guid, snapshots, :receive)
           ),
         :ok <- receive_properties(name),
         true <- unmounted_child?(identity, name),
         {:ok, ^identity} <- inspect_path(identity.path),
         do: :ok,
         else: (_ -> {:error, :zfs_receive_unconfirmed})
  end

  # @cc [owner:ghuntley,label:security;recovery] resume-token-requires-staging-lineage
  # resume_child/4 requires the pool lock, stream quiescence and independently
  # verified active local import ownership. It MUST require unchanged backing and
  # filesystem GUID, exact retained baseline snapshots, unmounted read-only noauto
  # staging and local safe properties. Return only a bounded unchanged native token;
  # source-side decoding/lineage validation and current authority remain mandatory.
  # Success grants neither allocation credit nor permission to execute a stream.
  @spec resume_child(t(), String.t(), String.t(), snapshots()) ::
          {:ok, String.t()} | {:error, :zfs_resume_unconfirmed}
  def resume_child(identity, name, guid, snapshots) do
    with {:ok, ^identity} <- inspect_path(identity.path),
         {:ok, token} when token != "-" and byte_size(token) <= 8192 <- receive_token(name),
         true <- unmounted_child?(identity, name),
         {:ok, before} <- read_datasets(name, true),
         {:ok, after_read} <- read_datasets(name, true),
         true <- stable_properties(before) == stable_properties(after_read),
         true <-
           Enum.all?(
             [before, after_read],
             &transfer_tree?(&1, identity, name, guid, snapshots, :abort_receive)
           ),
         {:ok, ^token} <- receive_token(name),
         true <- unmounted_child?(identity, name),
         {:ok, ^identity} <- inspect_path(identity.path),
         do: {:ok, token},
         else: (_ -> {:error, :zfs_resume_unconfirmed})
  end

  defp receive_properties(name) do
    with {:ok, false} <- receive_state(name), do: :ok, else: (_ -> :error)
  end

  defp receive_state(name) do
    with {:ok, token} <- receive_token(name), do: {:ok, token != "-"}
  end

  defp receive_token(name) do
    with {:ok, output} <-
           Command.run(:zfs_get, [
             "-Hp",
             "-o",
             "property,value,source",
             "exec,setuid,devices,receive_resume_token",
             name
           ]),
         rows = String.split(output, "\n", trim: true),
         true <- length(rows) == 4,
         parsed = Enum.map(rows, &String.split(&1, "\t")),
         true <- Enum.all?(~w(exec setuid devices), &([&1, "off", "local"] in parsed)),
         ["receive_resume_token", token, _] when byte_size(token) > 0 <-
           Enum.find(parsed, &match?(["receive_resume_token", _, _], &1)),
         do: {:ok, token},
         else: (_ -> :error)
  end

  # @cc [owner:ghuntley,label:security;recovery] import-cleanup-native-identity
  # cleanup_child/5 requires durable local retirement, the pool lock and proven
  # stream/VMM quiescence. It MUST match the child GUID, exact known surviving
  # snapshot GUIDs, local safe properties, backing and exclusive canonical mounts.
  # Only unadopted read-only unmounted staging may retain a resume token. The
  # staging may retain child-accounted bytes without another visible filesystem;
  # abort MUST clear this state before ordinary destruction checks. The adoption
  # policy requires a separately verified local import claim. Returned
  # resume state MUST NOT expose the token or grant authority to start a stream.
  @spec cleanup_child(t(), String.t(), String.t(), snapshots(), :staging | :adoption) ::
          {:ok, snapshots(), :mounted | :unmounted, boolean()}
          | {:error, :zfs_import_cleanup_unconfirmed}
  def cleanup_child(identity, name, guid, snapshots, policy)
      when policy in [:staging, :adoption] do
    with {:ok, ^identity} <- inspect_path(identity.path),
         {:ok, resumable} <- receive_state(name),
         true <- policy == :staging or not resumable,
         {:ok, before} <- read_datasets(name, true),
         {:ok, after_read} <- read_datasets(name, true),
         true <- stable_properties(before) == stable_properties(after_read),
         retained = Map.take(snapshots, Map.keys(before)),
         mode = cleanup_mode(policy, resumable),
         true <-
           Enum.all?(
             [before, after_read],
             &transfer_tree?(&1, identity, name, guid, retained, mode)
           ),
         mounted = before[name]["mounted"] == "yes",
         true <- adoption_mounts?(identity, name, mounted),
         {:ok, ^resumable} <- receive_state(name),
         {:ok, ^identity} <- inspect_path(identity.path),
         do: {:ok, retained, if(mounted, do: :mounted, else: :unmounted), resumable},
         else: (_ -> {:error, :zfs_import_cleanup_unconfirmed})
  end

  defp cleanup_mode(:staging, true), do: :abort_receive
  defp cleanup_mode(:staging, false), do: :receive
  defp cleanup_mode(:adoption, false), do: :adopt_publish

  # @cc [owner:ghuntley,label:recovery] child-absence-includes-mounts-and-descendants
  # absent_child/2 MUST verify unchanged parent/backing identity and absence of
  # the canonical child, its snapshots/descendants and every relevant mount alias.
  # It does not retire local metadata or release any reservation.
  @spec absent_child(t(), String.t()) :: :ok | {:error, :zfs_child_absence_unconfirmed}
  def absent_child(identity, name) do
    with {:ok, ^identity} <- inspect_path(identity.path),
         {:ok, entries} <- owners(identity),
         true <-
           Enum.all?(
             Map.keys(entries),
             &(&1 != name and not String.starts_with?(&1, [name <> "@", name <> "#", name <> "/"]))
           ),
         true <- unmounted_child?(identity, name),
         {:ok, ^identity} <- inspect_path(identity.path),
         do: :ok,
         else: (_ -> {:error, :zfs_child_absence_unconfirmed})
  end

  # @cc [owner:ghuntley,label:security;recovery] import-transition-is-not-ordinary-observation
  # adoption_child/5 requires independently verified local adoption intent and the
  # pool lock. Pruning MAY accept only a subset of the exact received snapshots;
  # later stages MUST require none. It MUST retain native GUID, safe properties,
  # backing identity and exclusive canonical mount checks through interrupted
  # mount/property changes. This API grants no capacity or execution authority.
  @spec adoption_child(
          t(),
          String.t(),
          String.t(),
          snapshots(),
          :pruning | :mounting | :publishing
        ) ::
          {:ok, snapshots(), :mounted | :unmounted} | {:error, :zfs_import_unconfirmed}
  def adoption_child(identity, name, guid, snapshots, stage)
      when stage in [:pruning, :mounting, :publishing] do
    with {:ok, ^identity} <- inspect_path(identity.path),
         :ok <- receive_properties(name),
         {:ok, before} <- read_datasets(name, true),
         {:ok, after_read} <- read_datasets(name, true),
         true <- stable_properties(before) == stable_properties(after_read),
         retained = if(stage == :pruning, do: Map.take(snapshots, Map.keys(before)), else: %{}),
         mode = %{pruning: :receive, mounting: :adopt_readonly, publishing: :adopt_publish}[stage],
         true <-
           Enum.all?(
             [before, after_read],
             &transfer_tree?(&1, identity, name, guid, retained, mode)
           ),
         mounted = before[name]["mounted"] == "yes",
         true <- adoption_mounts?(identity, name, mounted),
         :ok <- receive_properties(name),
         {:ok, ^identity} <- inspect_path(identity.path) do
      {:ok, retained, if(mounted, do: :mounted, else: :unmounted)}
    else
      _ -> {:error, :zfs_import_unconfirmed}
    end
  end

  defp adoption_mounts?(identity, name, mounted) do
    id = String.replace_prefix(name, identity.storage.dataset <> "/vm-", "")
    path = Path.join([identity.path, "vms", id])

    with true <- OverallsProtocol.uuid?(id),
         {:ok, output} <-
           Command.run(:findmnt, ["--json", "--list", "--output", "TARGET,SOURCE,FSTYPE,FSROOT"]),
         {:ok, %{"filesystems" => mounts}} when is_list(mounts) and length(mounts) <= 32_768 <-
           JSON.decode(output),
         true <- Enum.all?(mounts, &(is_binary(&1["source"]) and is_binary(&1["target"]))) do
      relevant =
        Enum.filter(mounts, fn row ->
          source = row["source"]
          target = row["target"]

          source == name or String.starts_with?(source, [name <> "[", name <> "@", name <> "/"]) or
            target == path or String.starts_with?(target, path <> "/")
        end)

      if mounted do
        case relevant do
          [%{"source" => ^name, "target" => ^path, "fstype" => "zfs", "fsroot" => "/"}] -> true
          _ -> false
        end
      else
        relevant == []
      end
    else
      _ -> false
    end
  end

  defp unmounted_child?(identity, name) do
    id = String.replace_prefix(name, identity.storage.dataset <> "/vm-", "")
    path = Path.join([identity.path, "vms", id])

    with true <- OverallsProtocol.uuid?(id),
         {:ok, output} <- Command.run(:findmnt, ["--json", "--list", "--output", "TARGET,SOURCE"]),
         {:ok, %{"filesystems" => mounts}} when is_list(mounts) and length(mounts) <= 32_768 <-
           JSON.decode(output) do
      Enum.all?(mounts, fn
        %{"source" => source, "target" => target} when is_binary(source) and is_binary(target) ->
          source != name and not String.starts_with?(source, name <> "[") and
            not String.starts_with?(source, name <> "@") and
            not String.starts_with?(source, name <> "/") and
            target != path and not String.starts_with?(target, path <> "/")

        _ ->
          false
      end)
    else
      _ -> false
    end
  end

  defp transfer_tree?(entries, identity, name, guid, snapshots, mode \\ :active) do
    with true <- map_size(entries) in 1..4 and map_size(snapshots) <= 3,
         {:ok, retained} <-
           snapshot_bindings(entries, snapshots, identity, mode == :abort_receive),
         %{^name => %{"guid" => ^guid} = row} = filesystems <-
           Map.drop(entries, Map.keys(snapshots)),
         true <- map_size(filesystems) == 1,
         true <- child?({name, row}, identity, mode == :abort_receive),
         true <-
           policy?(
             row,
             case mode do
               value when value in [:receive, :abort_receive] -> "no"
               value when value in [:adopt_readonly, :adopt_publish] -> row["mounted"]
               _ -> "yes"
             end,
             Map.has_key?(retained, name),
             mode
           ),
         true <- Map.get(retained, name, 0) <= row["usedbysnapshots"] do
      true
    else
      _ -> false
    end
  end

  # @cc [owner:ghuntley,label:capacity] zfs-exclusive-physical-decomposition
  # accounting/3 MUST reject unlisted/replaced snapshots, bookmarks, clones, nested
  # descendants and inconsistent physical decomposition. Snapshot expectations require
  # independent host-local ownership verification; this pure function does not establish it.
  # Empty expectations MUST preserve snapshot rejection. Only named lilly-b/lilly-backup
  # snapshots bound to the exact child filesystem GUID may participate. Dataset GUIDs MUST
  # be unique in the pool; snapshot GUIDs MUST be unique per dataset and never equal a
  # dataset GUID, since zfs receive preserves them across a same-pool clone copy. Physical bytes
  # MUST use usedbydataset + usedbysnapshots, never the sum of individual snapshot used
  # (shared retained blocks are absent from that sum). No allocation credit is granted.
  @spec accounting(tree(), t(), snapshots(), MapSet.t(String.t())) :: {:ok, map()} | :error
  def accounting(entries, identity, snapshots \\ %{}, staged \\ MapSet.new()) do
    case classify_accounting(entries, identity, snapshots, staged) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> :error
    end
  end

  # Which accounting check rejected a tree, as a closed atom for diagnostics.
  @type accounting_rejection ::
          :shape
          | :snapshot_binding
          | :filesystem_count
          | :parent_missing
          | :parent_guid
          | :parent_policy
          | :row_name
          | :duplicate_guid
          | :staged_child
          | :child
          | :children_usage
          | :total
          | :incoherent

  @doc false
  @spec classify_accounting(term(), t(), term(), MapSet.t(String.t())) ::
          {:ok, map()} | {:error, accounting_rejection()}
  def classify_accounting(entries, identity, snapshots, staged)
      when is_map(entries) and is_map(snapshots) do
    name = identity.storage.dataset

    with {:shape, true} <-
           {:shape, map_size(entries) in 1..@maximum_rows and map_size(snapshots) <= 12288},
         {:snapshot_binding, {:ok, retained}} <-
           {:snapshot_binding, snapshot_bindings(entries, snapshots, identity)},
         filesystems = Map.drop(entries, Map.keys(snapshots)),
         {:filesystem_count, true} <- {:filesystem_count, map_size(filesystems) in 1..4097},
         {:parent_missing, %{^name => parent}} <- {:parent_missing, filesystems},
         {:parent_guid, true} <- {:parent_guid, parent["guid"] == identity.storage.dataset_guid},
         {:parent_policy, true} <-
           {:parent_policy, parent["mountpoint"] == identity.path and policy?(parent)},
         {:row_name, true} <-
           {:row_name, Enum.all?(entries, fn {name, row} -> row["name"] == name end)},
         {:duplicate_guid, true} <- {:duplicate_guid, distinct_guids?(entries, filesystems)},
         children = Map.delete(filesystems, name),
         {:children, nil} <-
           {:children,
            Enum.find_value(children, &child_rejection(&1, identity, retained, staged))},
         {:children_usage, true} <-
           {:children_usage,
            parent["usedbychildren"] == Enum.sum(Enum.map(children, fn {_, r} -> r["used"] end))},
         total = parent["used"] + parent["available"],
         {:total, true} <- {:total, total <= @maximum},
         observation =
           Map.merge(identity.storage, %{
             used_bytes: parent["used"],
             logical_used_bytes: parent["logicalused"],
             quota_bytes: if(parent["quota"] == 0, do: nil, else: parent["quota"]),
             compression_ratio: parent["compressratio"]
           }),
         {:incoherent, true} <-
           {:incoherent, Storage.coherent?(observation, total, parent["available"])} do
      {:ok,
       %{
         total_bytes: total,
         free_bytes: parent["available"],
         storage: observation,
         snapshots: snapshots,
         children:
           Map.new(children, fn {name, row} ->
             {name,
              %{
                dataset_guid: row["guid"],
                physical_bytes: row["usedbydataset"] + row["usedbysnapshots"],
                mountpoint: row["mountpoint"],
                readonly: row["readonly"]
              }}
           end)
       }}
    else
      {:children, reason} -> {:error, reason}
      {reason, _} -> {:error, reason}
    end
  end

  def classify_accounting(_, _, _, _), do: {:error, :shape}

  # Dataset GUIDs are unique across the pool. A snapshot GUID is unique within its
  # dataset and never equals a dataset GUID, but zfs receive preserves snapshot
  # GUIDs, so a same-pool clone copy legitimately repeats its source's.
  @spec distinct_guids?(tree(), tree()) :: boolean()
  defp distinct_guids?(entries, filesystems) do
    datasets = Enum.map(filesystems, fn {_, row} -> row["guid"] end)

    snapshots =
      for {name, row} <- entries,
          not Map.has_key?(filesystems, name),
          do: {name |> String.split("@", parts: 2) |> hd(), row["guid"]}

    dataset_set = MapSet.new(datasets)

    MapSet.size(dataset_set) == length(datasets) and
      length(Enum.uniq(snapshots)) == length(snapshots) and
      not Enum.any?(snapshots, fn {_, guid} -> MapSet.member?(dataset_set, guid) end)
  end

  @spec child_rejection({String.t(), map()}, t(), map(), MapSet.t(String.t())) ::
          nil | :staged_child | :child
  defp child_rejection({name, row}, identity, retained, staged) do
    retained? = Map.has_key?(retained, name)

    if MapSet.member?(staged, name) do
      # A finished, owned, unadopted import: receive policy, never mounted.
      unless policy?(row, "no", retained?, :receive) and child?({name, row}, identity) and
               Map.get(retained, name, 0) <= row["usedbysnapshots"],
             do: :staged_child
    else
      unless (policy?(row, "yes", retained?) and child?({name, row}, identity) and
                Map.get(retained, name, 0) <= row["usedbysnapshots"]) or
               template_row?({name, row}, identity),
             do: :child
    end
  end

  # @cc [owner:ghuntley,label:security;capacity] template-native-shape-no-credit
  # Template inspection MUST require a direct, mounted, snapshot-free independent
  # dataset with the exact pool binding, GUID and requested seal. It grants no
  # allocation credit; the caller independently matches the durable nonce/owner.
  @spec template_child(t(), String.t(), String.t() | nil, :on | :off | :either) ::
          {:ok, String.t()} | {:error, :template_unconfirmed}
  def template_child(identity, name, guid, seal),
    do: artifact_child(identity, name, guid, seal, :template, true)

  defp artifact_child(identity, name, guid, seal, kind, sealed_execution?) do
    with true <- not sealed_execution? or execution_sealed?(name),
         {:ok, parents} <- read_datasets(identity.storage.dataset, false),
         {:ok, rows} <- read_datasets(name, true) do
      artifact_rows(identity, parents, rows, name, guid, seal, kind)
    else
      _ -> {:error, :template_unconfirmed}
    end
  end

  @typedoc "The only artifact kind: a sealed image template (standbys retired, ADR-0177)."
  @type artifact_kind :: :template

  @typedoc "The summary an observation returns for each direct child dataset."
  @type observed_child :: %{
          dataset_guid: String.t(),
          physical_bytes: non_neg_integer(),
          mountpoint: String.t(),
          readonly: String.t()
        }

  # @cc [owner:ghuntley,label:security;capacity] artifact-rows-are-targeted-shape
  # artifact_rows/7 is the targeted-read predicate: the parent row MUST keep its
  # GUID, mountpoint and policy, the artifact MUST be the only row under its name
  # (no snapshot, bookmark or descendant), and the row MUST have the kind's exact
  # native shape, mountpoint, GUID and requested seal. It grants no credit.
  @doc false
  @spec artifact_rows(
          t(),
          tree(),
          tree(),
          String.t(),
          String.t() | nil,
          :on | :off | :either,
          artifact_kind()
        ) :: {:ok, String.t()} | {:error, :template_unconfirmed}
  def artifact_rows(identity, parents, rows, name, guid, seal, kind) do
    with parent when is_map(parent) <- parents[identity.storage.dataset],
         true <-
           parent["guid"] == identity.storage.dataset_guid and
             parent["mountpoint"] == identity.path and policy?(parent),
         %{^name => row} when map_size(rows) == 1 <- rows,
         true <- artifact_row?({name, row}, identity, kind),
         true <- row["mountpoint"] == artifact_mountpoint(identity, name, kind),
         true <- is_nil(guid) or row["guid"] == guid,
         true <- seal == :either or row["readonly"] == Atom.to_string(seal) do
      {:ok, row["guid"]}
    else
      _ -> {:error, :template_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security;capacity] observed-artifact-equals-targeted-read
  # observed_artifact/6 MUST accept exactly what artifact_rows/7 accepts for a
  # tree that accounting accepted (ADR-0152): accounting has validated the
  # parent, refused every unknown snapshot or descendant and checked each
  # template row's native shape, so only the kind's mountpoint, GUID
  # and seal remain. Callers MUST pass children observed under the pool lock
  # they still hold, never an observation read before that lock was acquired.
  @doc false
  @spec observed_artifact(
          t(),
          %{String.t() => observed_child()},
          String.t(),
          String.t() | nil,
          :on | :off | :either,
          artifact_kind()
        ) :: {:ok, String.t()} | {:error, :template_unconfirmed}
  def observed_artifact(identity, children, name, guid, seal, kind) do
    with %{dataset_guid: observed, mountpoint: mountpoint, readonly: readonly} <- children[name],
         true <- artifact_name?(identity, name, kind),
         true <- mountpoint == artifact_mountpoint(identity, name, kind),
         true <- is_nil(guid) or observed == guid,
         true <- seal == :either or readonly == Atom.to_string(seal) do
      {:ok, observed}
    else
      _ -> {:error, :template_unconfirmed}
    end
  end

  defp artifact_row?(entry, identity, :template), do: template_row?(entry, identity)

  defp artifact_name?(identity, name, kind) do
    prefix = artifact_prefix(identity, kind)

    String.starts_with?(name, prefix) and
      OverallsProtocol.uuid?(String.replace_prefix(name, prefix, ""))
  end

  defp artifact_prefix(identity, :template), do: identity.storage.dataset <> "/template-"

  defp artifact_mountpoint(identity, name, :template = kind) do
    id = String.replace_prefix(name, artifact_prefix(identity, kind), "")
    Path.join([identity.path, "templates", id])
  end

  defp template_row?({name, row}, identity) do
    prefix = identity.storage.dataset <> "/template-"
    id = String.replace_prefix(name, prefix, "")

    String.starts_with?(name, prefix) and OverallsProtocol.uuid?(id) and
      row["mountpoint"] == Path.join([identity.path, "templates", id]) and
      row["usedbychildren"] == 0 and row["quota"] == 0 and
      policy?(row, "yes", false, :template)
  end

  defp execution_sealed?(name) do
    with {:ok, properties} <-
           Command.run(:zfs_get, [
             "-H",
             "-o",
             "property,value,source",
             "exec,setuid,devices",
             name
           ]) do
      Enum.sort(String.split(properties, "\n", trim: true)) ==
        Enum.sort(Enum.map(~w(exec setuid devices), &(&1 <> "\toff\tlocal")))
    else
      _ -> false
    end
  end

  defp snapshot_bindings(entries, snapshots, identity, resumable? \\ false) do
    Enum.reduce_while(snapshots, {:ok, %{}}, fn {name, expected}, {:ok, retained} ->
      with true <- is_binary(name),
           [dataset, suffix] when suffix in ["lilly-b", "lilly-backup"] <-
             String.split(name, "@"),
           %{dataset_guid: dataset_guid, snapshot_guid: snapshot_guid}
           when map_size(expected) == 2 <- expected,
           true <- guid?(dataset_guid) and guid?(snapshot_guid),
           %{"guid" => ^dataset_guid, "type" => "filesystem"} = child <- entries[dataset],
           true <- child?({dataset, child}, identity, resumable?),
           %{"guid" => ^snapshot_guid, "type" => "snapshot"} = row <- entries[name],
           true <- snapshot_row?(row) do
        {:cont, {:ok, Map.update(retained, dataset, row["used"], &(&1 + row["used"]))}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp snapshot_row?(row) do
    Enum.all?(@snapshot_absent, &(row[&1] == "-")) and
      is_integer(row["used"]) and row["used"] in 0..@maximum and
      is_float(row["compressratio"]) and row["compressratio"] > 0 and
      row["compressratio"] <= 1_000_000
  end

  @spec properties() :: [String.t()]
  def properties, do: @properties

  @doc "Read child ownership tags and GUIDs; the caller must match durable claims separately."
  @spec owners(t()) :: {:ok, %{String.t() => map()}} | :error
  def owners(identity), do: owners(identity, identity.storage.dataset)

  @doc "Ownership tags under one dataset of this pool: the parent or one of its descendants."
  @spec owners(t(), String.t()) :: {:ok, %{String.t() => map()}} | :error
  def owners(identity, root) do
    with true <-
           root == identity.storage.dataset or
             String.starts_with?(root, identity.storage.dataset <> "/"),
         {:ok, output} <-
           Command.run(:zfs_list, [
             "-Hpr",
             "-t",
             "all",
             "-o",
             "name,guid,lilly:host,lilly:pool,lilly:vm,lilly:nonce",
             root
           ]),
         rows = String.split(output, "\n", trim: true),
         true <- length(rows) in 1..@maximum_rows do
      parse_owners(rows)
    else
      _ -> :error
    end
  end

  defp parse_owners(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      case String.split(row, "\t") do
        [name, guid, host, pool, vm, nonce] ->
          if guid?(guid) and not Map.has_key?(acc, name) do
            {:cont,
             {:ok,
              Map.put(acc, name, %{
                "guid" => guid,
                "host" => host,
                "pool" => pool,
                "vm" => vm,
                "nonce" => nonce
              })}}
          else
            {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
  end

  @typedoc "One findmnt row: target, source, fstype and fsroot."
  @type mount :: %{String.t() => String.t() | nil}

  @doc "The bounded host mount table (target, source, fstype, fsroot) for exclusive-mount checks."
  @spec mounts() :: {:ok, [mount()]} | :error
  def mounts do
    with {:ok, output} <-
           Command.run(:findmnt, ["--json", "--list", "--output", "TARGET,SOURCE,FSTYPE,FSROOT"]),
         {:ok, %{"filesystems" => mounts}} when is_list(mounts) and length(mounts) <= 32_768 <-
           JSON.decode(output),
         true <- Enum.all?(mounts, &is_map/1),
         do: {:ok, mounts},
         else: (_ -> :error)
  end

  # @cc [owner:ghuntley,label:security] zfs-property-parser-bounds
  # parse_datasets/1 MUST reject malformed, duplicate, oversized and noncanonical rows. Values
  # read from ZFS MUST NOT create atoms or silently replace an earlier dataset entry.
  @spec parse_datasets(binary()) :: {:ok, tree()} | :error
  def parse_datasets(output) when is_binary(output) and byte_size(output) <= 4_194_304 do
    with true <- String.valid?(output) and String.ends_with?(output, "\n"),
         rows = output |> String.trim_trailing("\n") |> String.split("\n"),
         true <- length(rows) in 1..@maximum_rows do
      Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, entries} ->
        with values = String.split(row, "\t"),
             true <- length(values) == length(@properties),
             {:ok, parsed} <- parse_row(Map.new(Enum.zip(@properties, values))),
             false <- Map.has_key?(entries, parsed["name"]) do
          {:cont, {:ok, Map.put(entries, parsed["name"], parsed)}}
        else
          _ -> {:halt, :error}
        end
      end)
    else
      _ -> :error
    end
  end

  def parse_datasets(_), do: :error

  # @cc [owner:ghuntley,label:security;capacity] zfs-status-supported-topology
  # parse_status/2 MUST accept only healthy plain disk/mirror data vdevs with unique GUIDs
  # and paths. Unknown allocation classes, spares, caches, errors or degraded health MUST
  # withhold admission evidence; this reader MUST NOT stop or delete existing VMs.
  @spec parse_status(binary(), String.t()) :: {:ok, String.t(), [Path.t()]} | :error
  def parse_status(output, pool) do
    with {:ok,
          %{
            "output_version" => %{
              "command" => "zpool status",
              "vers_major" => 0,
              "vers_minor" => 1
            },
            "pools" => pools
          }} <- JSON.decode(output),
         %{^pool => status} when map_size(pools) == 1 <- pools,
         true <- is_map(status),
         true <- status["name"] == pool and status["state"] == "ONLINE",
         true <- status["error_count"] == "0" and guid?(status["pool_guid"]),
         true <-
           Enum.all?(~w(logs special dedup cache l2cache spares), &absent_or_empty?(status, &1)),
         %{^pool => root} = roots when map_size(roots) == 1 <- status["vdevs"],
         true <- is_map(root),
         true <- root["vdev_type"] == "root" and root["guid"] == status["pool_guid"],
         {:ok, leaves, guids} <- vdev(root, 0),
         true <- length(leaves) in 1..64 and length(Enum.uniq(leaves)) == length(leaves),
         true <- length(Enum.uniq(guids)) == length(guids) do
      {:ok, status["pool_guid"], Enum.sort(leaves)}
    else
      _ -> :error
    end
  end

  defp read_datasets(name, recursive) do
    arguments =
      ["-Hp", "-t", "all", "-o", Enum.join(@properties, ",")] ++
        if(recursive, do: ["-r", name], else: [name])

    with {:ok, output} <- Command.run(:zfs_list, arguments), do: parse_datasets(output)
  end

  defp parse_row(row) do
    with true <- byte_size(row["name"]) in 1..280,
         true <- not String.contains?(row["name"], ["\r", "\0"]),
         true <- guid?(row["guid"]),
         {ratio, ""} when ratio > 0 and ratio <= 1_000_000 <- Float.parse(row["compressratio"]),
         {:ok, row} <- numbers(row) do
      {:ok, Map.put(row, "compressratio", ratio)}
    else
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:capacity;security] snapshot-absence-is-not-zero-capacity
  # Snapshot rows MUST retain native not-applicable fields as "-", never fabricate
  # numeric capacity or filesystem policy. Only used is an integer for the selected
  # snapshot properties. Parsing snapshots MUST NOT establish ownership or admission:
  # accounting/3 accepts them only with independently supplied ownership bindings.
  defp numbers(%{"type" => "snapshot"} = row) do
    with true <- Enum.all?(@snapshot_absent, &(row[&1] == "-")),
         [dataset, snapshot] when dataset != "" and snapshot != "" <-
           String.split(row["name"], "@"),
         {:ok, used} <- number(row["used"]) do
      {:ok, Map.put(row, "used", used)}
    else
      _ -> :error
    end
  end

  defp numbers(row) do
    Enum.reduce_while(@integers, {:ok, row}, fn key, {:ok, acc} ->
      case number(acc[key]) do
        {:ok, number} -> {:cont, {:ok, Map.put(acc, key, number)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp policy?(row, mounted \\ "yes", snapshots? \\ false, mode \\ :active) do
    policy_shape?(row, mounted, snapshots?, mode) and
      row["used"] == row["usedbychildren"] + row["usedbydataset"] + row["usedbysnapshots"]
  end

  defp policy_shape?(row, mounted, snapshots?, mode) do
    readonly =
      case mode do
        value when value in [:receive, :adopt_readonly, :abort_receive] -> ["on"]
        :adopt_publish -> ["on", "off"]
        :template -> ["on", "off"]
        _ -> ["off"]
      end

    canmount =
      case mode do
        value when value in [:receive, :adopt_readonly, :abort_receive] -> ["noauto"]
        :adopt_publish -> ["noauto", "on"]
        _ -> ["on"]
      end

    Enum.all?(@integers, fn key ->
      is_integer(row[key]) and row[key] >= 0 and row[key] <= @maximum
    end) and
      guid?(row["guid"]) and row["type"] == "filesystem" and mounted in ["yes", "no"] and
      row["mounted"] == mounted and
      row["compression"] == "lz4" and row["reservation"] == 0 and row["refreservation"] == 0 and
      row["dedup"] == "off" and row["sync"] == "standard" and row["origin"] == "-" and
      row["readonly"] in readonly and row["canmount"] in canmount and row["refquota"] == 0 and
      row["usedbyrefreservation"] == 0 and (snapshots? or row["usedbysnapshots"] == 0)
  end

  defp child?({name, row}, identity, resumable? \\ false) do
    prefix = identity.storage.dataset <> "/vm-"
    id = String.replace_prefix(name, prefix, "")

    String.starts_with?(name, prefix) and OverallsProtocol.uuid?(id) and
      row["mountpoint"] == Path.join([identity.path, "vms", id]) and
      (row["usedbychildren"] == 0 or resumable?) and row["quota"] == 0
  end

  defp mounted_dataset(path) do
    with {:ok, output} <-
           Command.run(:findmnt, [
             "--json",
             "--target",
             path,
             "--output",
             "FSTYPE,SOURCE,TARGET,FSROOT,OPTIONS",
             "--first-only"
           ]),
         {:ok, %{"filesystems" => [mount]}} <- JSON.decode(output),
         %{"fstype" => "zfs", "target" => ^path, "fsroot" => "/", "source" => dataset} <- mount,
         true <- is_binary(dataset) and byte_size(dataset) <= 200,
         true <-
           Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9_.-]*(\/[a-zA-Z0-9][a-zA-Z0-9_.-]*)+\z/, dataset),
         options when is_binary(options) <- mount["options"],
         true <- "rw" in String.split(options, ",") do
      {:ok, dataset}
    else
      _ -> :error
    end
  end

  defp vdev(row, depth) when is_map(row) and depth <= 2 do
    with true <- row["class"] == "normal" and row["state"] == "ONLINE",
         true <- Enum.all?(~w(read_errors write_errors checksum_errors), &(row[&1] == "0")),
         true <- guid?(row["guid"]) do
      case row["vdev_type"] do
        "disk" when depth in [1, 2] ->
          path = row["path"]

          if is_binary(path) and byte_size(path) <= 4096 and String.starts_with?(path, "/dev/") and
               not String.contains?(path, ["\0", "\n", "\r"]) and absent_or_empty?(row, "vdevs"),
             do: {:ok, [path], [row["guid"]]},
             else: :error

        type when (type == "root" and depth == 0) or (type == "mirror" and depth == 1) ->
          case row["vdevs"] do
            children when is_map(children) and map_size(children) in 1..64 ->
              Enum.reduce_while(children, {:ok, [], [row["guid"]]}, fn {_, child},
                                                                       {:ok, paths, guids} ->
                case vdev(child, depth + 1) do
                  {:ok, next, ids} -> {:cont, {:ok, paths ++ next, guids ++ ids}}
                  _ -> {:halt, :error}
                end
              end)

            _ ->
              :error
          end

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp vdev(_, _), do: :error

  defp extents(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, canonical} <- canonical(path),
           {:ok, %File.Stat{type: :device, mode: mode}} <- File.stat(canonical),
           true <- Bitwise.band(mode, 0o170000) == 0o060000,
           {:ok, numbers} <- Command.run(:stat, ["--printf=%t:%T", "--", canonical]),
           [major, minor] <- String.split(numbers, ":"),
           {major, ""} <- Integer.parse(major, 16),
           {minor, ""} <- Integer.parse(minor, 16),
           {:ok, extent} <- Pool.device_extent("/sys", "#{major}:#{minor}") do
        {:cont, {:ok, [extent | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} ->
        if Pool.distinct_extents?(values), do: {:ok, Enum.sort(values)}, else: :error

      _ ->
        :error
    end
  end

  defp canonical(path) do
    with {:ok, output} <- Command.run(:realpath, ["--canonicalize-existing", "--", path]),
         do: {:ok, String.trim_trailing(output, "\n")}
  end

  defp absent_or_empty?(row, key), do: Map.get(row, key, %{}) == %{}

  defp number(value) when is_binary(value) and byte_size(value) in 1..19 do
    with true <- Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, value),
         {n, ""} when n <= @maximum <- Integer.parse(value),
         do: {:ok, n},
         else: (_ -> :error)
  end

  defp number(_), do: :error

  defp guid?(value) when is_binary(value) and byte_size(value) in 1..20,
    do:
      Regex.match?(~r/\A[1-9][0-9]*\z/, value) and
        String.to_integer(value) <= 18_446_744_073_709_551_615

  defp guid?(_), do: false
end
