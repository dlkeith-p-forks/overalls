defmodule Lilly.Control.Config do
  @moduledoc "Validated, private startup configuration. Paths and utilities are operator-owned, never VM inputs."
  alias Lilly.Control.Client
  alias Lilly.Host.{Identity, Image, Pool, PrivateFiles}

  @derive {Inspect, except: [:client]}
  @enforce_keys [:client, :state_dir, :cgroup_path, :pools]
  defstruct [
    :client,
    :state_dir,
    :cgroup_path,
    :pools,
    :execution,
    :transfer_state_dir,
    :ingress,
    images: [],
    transfer_bytes_per_second: 67_108_864,
    local_transfer_bytes_per_second: 1_073_741_824
  ]

  @type t :: %__MODULE__{
          client: Client.t(),
          state_dir: Path.t(),
          cgroup_path: Path.t(),
          pools: [Pool.t()],
          images: [Image.t()],
          execution: Lilly.VM.Config.t(),
          transfer_state_dir: Path.t() | nil,
          transfer_bytes_per_second: pos_integer(),
          local_transfer_bytes_per_second: pos_integer(),
          ingress: keyword() | nil
        }

  # @cc [owner:ghuntley,label:security] runtime-version-and-storage-binding
  # load/1 MUST reject older runtime configuration and require v4 execution to use
  # /sys/fs/cgroup/lilly.slice with distinct state directories, validated host identity and non-
  # overlapping bound pools before constructing the runtime. Transfer rates MUST
  # be positive integers at most 1 GiB/s; omission selects 64 MiB/s for peer
  # transfers and 1 GiB/s for same-host clone streams, which never cross a network.
  @spec load(Path.t()) :: {:ok, t()} | {:error, :invalid_runtime_configuration}
  def load(path) do
    with {:ok, encoded} <- PrivateFiles.read_secret(path),
         {:ok,
          %{
            "version" => version,
            "control_plane" => url,
            "host_id" => host,
            "state_dir" => state_dir,
            "cgroup_path" => cgroup_path,
            "pools" => pools
          } = config} <- JSON.decode(encoded),
         {:ok, token} <- credential(config, host),
         true <- version == 4 and is_binary(state_dir) and is_binary(cgroup_path),
         true <- Path.type(state_dir) == :absolute and Path.type(cgroup_path) == :absolute,
         true <- Path.expand(state_dir) == state_dir and Path.expand(cgroup_path) == cgroup_path,
         true <- is_list(pools) and length(pools) <= 64,
         {:ok, machine, execution} <- execution(version, host, state_dir, cgroup_path, config),
         true <-
           is_nil(execution.inception_image_id) or
             (is_binary(execution.inception_proof_file) and
                is_binary(execution.inception_probe_id)),
         {:ok, ingress} <-
           ingress(
             config["ingress"],
             execution.network.ingress or execution.network.private_services
           ),
         true <- not execution.network.private_services or is_list(ingress),
         {:ok, client} <-
           Client.new(url, host, token,
             cacertfile: config["cacertfile"],
             protocol_version: version,
             machine_id: machine,
             allow_insecure_loopback: config["allow_insecure_loopback"] == true
           ),
         {:ok, pools} <- pools(pools, host),
         true <- Enum.all?(pools, &Lilly.VM.Jail.supports_pool?/1),
         {:ok, images} <- images(Map.get(config, "images", [])),
         true <-
           is_nil(execution.inception_image_id) or
             Enum.any?(images, &(&1.id == execution.inception_image_id)),
         rate = Map.get(config, "transfer_bytes_per_second", 67_108_864),
         true <- is_integer(rate) and rate in 1..1_073_741_824,
         local_rate = Map.get(config, "local_transfer_bytes_per_second", 1_073_741_824),
         true <- is_integer(local_rate) and local_rate in 1..1_073_741_824,
         true <- Pool.distinct?(pools) and length(Enum.uniq_by(pools, & &1.id)) == length(pools),
         {:ok, transfer} <-
           transfer_directory(
             config["transfer_state_dir"],
             [
               state_dir,
               execution.state_dir,
               execution.network.state_dir | Enum.map(pools, & &1.path)
             ]
           ) do
      {:ok,
       %__MODULE__{
         client: client,
         state_dir: state_dir,
         cgroup_path: cgroup_path,
         pools: pools,
         execution: execution,
         transfer_state_dir: transfer,
         transfer_bytes_per_second: rate,
         local_transfer_bytes_per_second: local_rate,
         ingress: ingress,
         images: images
       }}
    else
      _ -> {:error, :invalid_runtime_configuration}
    end
  end

  # @cc [owner:ghuntley,label:security] ingress-explicit-local-startup
  # Audi connectors MUST require an explicit ingress or private-service exception and a closed
  # operator-owned socket/peer configuration. A missing or inconsistent half
  # MUST fail startup. Client input cannot select this path or backend.
  defp ingress(nil, false), do: {:ok, nil}

  defp ingress(%{"path" => path, "audi_uid" => uid} = value, true)
       when map_size(value) == 2 and is_binary(path) and byte_size(path) in 1..107 and
              is_integer(uid) and uid in 0..4_294_967_294 do
    if Path.type(path) == :absolute and Path.expand(path) == path and
         not String.contains?(path, [<<0>>, "\n", "\r"]) and path != "/" and
         not String.starts_with?(path, "/nix/store/"),
       do: {:ok, [path: path, audi_uid: uid]},
       else: :error
  end

  defp ingress(_, _), do: :error

  # @cc [owner:ghuntley,label:security] transfer-state-operator-path
  # Optional transfer state MUST use a canonical mutable absolute path disjoint
  # from execution/control/network state and pool contents. Absence disables
  # preparation; it MUST NOT derive a path from remote messages.
  defp transfer_directory(nil, _), do: {:ok, nil}

  defp transfer_directory(path, reserved) when is_binary(path) do
    if Path.type(path) == :absolute and Path.expand(path) == path and path != "/" and
         not String.starts_with?(path <> "/", "/nix/store/") and
         Enum.all?(reserved, fn other ->
           not String.starts_with?(path <> "/", other <> "/") and
             not String.starts_with?(other <> "/", path <> "/")
         end), do: {:ok, path}, else: :error
  end

  defp transfer_directory(_, _), do: :error

  # @cc [owner:ghuntley,label:security] credential-source-exclusive
  # credential/2 MUST accept exactly one of inline credential or credential_file; missing or
  # simultaneous sources must fail instead of silently choosing one.
  defp credential(config, host) do
    case {Map.fetch(config, "credential"), Map.fetch(config, "credential_file")} do
      {{:ok, token}, :error} when is_binary(token) -> {:ok, token}
      {:error, {:ok, path}} -> Lilly.Control.CredentialFile.read(path, host)
      _ -> :error
    end
  end

  defp execution(4, host, state, "/sys/fs/cgroup/lilly.slice", %{"execution" => value}) do
    with {:ok, machine} <- Identity.read(),
         %{
           "state_dir" => vm_state,
           "network_state_dir" => network_state,
           "egress_interface" => egress,
           "protected_cidrs" => protected,
           "firecracker" => fc,
           "jailer" => jailer,
           "unshare" => unshare
         } <- value,
         true <- length(Enum.uniq([state, vm_state, network_state])) == 3,
         {:ok, roots} <- guest_trust_roots(Map.get(value, "guest_trust_roots", [])),
         {:ok, network} <-
           Lilly.Network.Config.new(
             host,
             egress,
             protected,
             network_state,
             Map.get(value, "audi_ingress", false),
             Map.get(value, "private_services", false),
             Map.get(value, "brady")
           ),
         {:ok, driver} <-
           Lilly.VM.Config.new(%{
             state_dir: vm_state,
             network: network,
             firecracker: fc,
             jailer: jailer,
             unshare: unshare,
             inception_smtp_file: Map.get(value, "inception_smtp_file"),
             inception_image_id: Map.get(value, "inception_image_id"),
             inception_proof_file: Map.get(value, "inception_proof_file"),
             inception_probe_id: Map.get(value, "inception_probe_id"),
             firecracker_logging: Map.get(value, "firecracker_logging", false),
             guest_trust_roots: roots
           }) do
      {:ok, machine, driver}
    else
      _ -> :error
    end
  end

  defp execution(_, _, _, _, _), do: :error

  defp guest_trust_roots(paths) when is_list(paths) and length(paths) <= 32 do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, roots} ->
      if is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path do
        case File.read(path) do
          {:ok, pem} when byte_size(pem) in 1..16_384 -> {:cont, {:ok, [pem | roots]}}
          _ -> {:halt, :error}
        end
      else
        {:halt, :error}
      end
    end)
    |> case do
      {:ok, roots} -> {:ok, Enum.reverse(roots)}
      _ -> :error
    end
  end

  defp guest_trust_roots(_), do: :error

  # @cc [owner:ghuntley,label:capacity] configured-image-shape
  # Each configured image is an object holding only its manifest directory
  # `path`. Configuration order is preserved so the catalog verifies images in
  # the operator's order; a bare path, the retired `standby` key (ADR-0177) or
  # any other shape refuses the configuration (ADR-0159: one shape).
  defp images(entries) when is_list(entries) and length(entries) <= 128 do
    Enum.reduce_while(entries, {:ok, []}, fn
      %{"path" => path} = entry, {:ok, images}
      when map_size(entry) == 1 and is_binary(path) ->
        case Image.stage(path) do
          {:ok, image} -> {:cont, {:ok, [image | images]}}
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, images} ->
        if length(Enum.uniq_by(images, & &1.id)) == length(images),
          do: {:ok, Enum.reverse(images)},
          else: :error

      _ ->
        :error
    end
  end

  defp images(_), do: :error

  if System.get_env("ANTITHESIS_HARNESS") == "1" and
       System.get_env("ANTITHESIS_INTEGRATED_HOST") != "1" do
    Code.eval_quoted(
      quote do
        defp pools(values, host), do: OverallsAntithesis.Lilly.PoolConfig.decode(values, host)
      end,
      [],
      __ENV__
    )
  else
    defp pools(values, host) do
      Enum.reduce_while(values, {:ok, []}, fn
        %{"id" => id, "path" => path, "filesystem_id" => fs} = value, {:ok, acc}
        when is_binary(path) ->
          with true <- Pool.configuration_keys?(value),
               {:ok, pool} <-
                 Pool.new(id, path, fs,
                   max_iops: value["max_iops"],
                   max_iops_source: value["max_iops_source"],
                   host_id: host,
                   storage: value["storage"],
                   template_budget_bytes: Map.get(value, "template_budget_bytes", 34_359_738_368),
                   image_io_timeout_ms: Map.get(value, "image_io_timeout_ms", 300_000)
                 ) do
            {:cont, {:ok, [pool | acc]}}
          else
            _ -> {:halt, :error}
          end

        _, _ ->
          {:halt, :error}
      end)
      |> case do
        {:ok, pools} -> {:ok, Enum.reverse(pools)}
        _ -> :error
      end
    end
  end
end
