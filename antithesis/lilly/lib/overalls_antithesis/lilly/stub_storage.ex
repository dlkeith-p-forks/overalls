defmodule OverallsAntithesis.Lilly.StubStorage do
  @moduledoc """
  Harness-only **stub** storage substrate for the `admission-stub` Antithesis
  profile. It is not ZFS and observes no block device, dataset or pool.

  The Lilly entrypoint writes one fixed substrate file when Compose selects the
  stub; this module turns it into a pool report with configured (not measured)
  totals so Marshall's real admission code has storage headroom to decide on.
  Memory headroom stays measured from the container's cgroups; CPU headroom is
  the file's labelled STUB budget capped by the measured effective cores,
  because the hosted single-CPU VM never measures a whole idle core. The advertised image is a tiny non-bootable artifact set that Lilly still
  digest-verifies with `Lilly.Host.Image.load/1`. The module exists only in
  `ANTITHESIS_HARNESS=1` builds.
  """
  alias Lilly.Host.{Image, Pool}

  @env "OVERALLS_ANTITHESIS_STORAGE_STUB_FILE"
  @scope "antithesis-harness-stub-not-zfs"
  @max_bytes 9_223_372_036_854_775_807
  @keys ~w(version scope zpool_guid dataset_guid dataset total_bytes free_bytes stub_cpu_millicores image_path)

  @type t :: %{
          identity: OverallsProtocol.Storage.identity(),
          total_bytes: pos_integer(),
          free_bytes: non_neg_integer(),
          stub_cpu_millicores: pos_integer(),
          image_path: Path.t()
        }

  @doc "The configured stub substrate, `:disabled` when Compose did not select it."
  # @cc [owner:ghuntley,label:capacity;verification] stub-storage-explicit-selection
  # The stub substrate MUST be used only when the harness environment names its
  # file. A named file that is missing, not a private (owner-only) regular file,
  # or not exactly the fixed versioned stub shape MUST fail closed as an error,
  # never fall back to configured or zero capacity.
  @spec read() :: {:ok, t()} | :disabled | {:error, :stub_storage_invalid}
  def read, do: read(System.get_env(@env))

  @spec read(String.t() | nil) :: {:ok, t()} | :disabled | {:error, :stub_storage_invalid}
  def read(nil), do: :disabled

  def read(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         {:ok, %File.Stat{type: :regular, mode: mode, size: size}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0 and size <= 4096,
         {:ok, body} <- File.read(path),
         {:ok, value} <- JSON.decode(body),
         {:ok, stub} <- decode(value) do
      {:ok, stub}
    else
      _ -> {:error, :stub_storage_invalid}
    end
  end

  @spec decode(term()) :: {:ok, t()} | :error
  defp decode(
         %{
           "version" => 1,
           "scope" => @scope,
           "zpool_guid" => zpool,
           "dataset_guid" => dataset_guid,
           "dataset" => dataset,
           "total_bytes" => total,
           "free_bytes" => free,
           "stub_cpu_millicores" => cpu,
           "image_path" => image_path
         } = value
       ) do
    identity = %{backend: :zfs, zpool_guid: zpool, dataset_guid: dataset_guid, dataset: dataset}

    if Enum.sort(Map.keys(value)) == Enum.sort(@keys) and
         OverallsProtocol.Storage.valid_identity?(identity) and
         is_integer(total) and total in 1..@max_bytes and
         is_integer(free) and free in 0..total and
         is_integer(cpu) and cpu in 1..65_536_000 and
         is_binary(image_path) and Path.type(image_path) == :absolute and
         Path.expand(image_path) == image_path do
      {:ok,
       %{
         identity: identity,
         total_bytes: total,
         free_bytes: free,
         stub_cpu_millicores: cpu,
         image_path: image_path
       }}
    else
      :error
    end
  end

  defp decode(_), do: :error

  @doc "Pool report entry for one configured pool against the stub substrate."
  # @cc [owner:ghuntley,label:capacity;verification] stub-pool-matches-enrolled-identity
  # A stub observation MUST name only the configured pool's enrolled storage
  # identity, carry no allocation credit and keep used bytes equal to total
  # minus free. A pool whose configured identity differs from the stub MUST be
  # reported unavailable, never credited.
  @spec pool_report(Pool.t(), t()) :: OverallsProtocol.pool()
  def pool_report(%Pool{storage: storage} = pool, %{identity: identity} = stub)
      when storage == identity do
    %{
      id: pool.id,
      total_bytes: stub.total_bytes,
      free_bytes: stub.free_bytes,
      allocations: %{},
      storage:
        Map.merge(identity, %{used_bytes: stub.total_bytes - stub.free_bytes, quota_bytes: nil})
    }
  end

  def pool_report(pool, _stub), do: %{id: pool.id, unavailable: true, storage: pool.storage}

  @doc "Digest-verified stub image IDs; any verification failure advertises none."
  @spec image_ids(t()) :: [String.t()]
  def image_ids(%{image_path: path}) do
    case Image.load(path) do
      {:ok, image} -> Image.available_ids([image])
      _ -> []
    end
  end

  @doc "Whether a stub-backed report may advertise placement readiness."
  # @cc [owner:ghuntley,label:capacity;verification] stub-readiness-requires-measured-report
  # Stub readiness MUST require the stub to be selected and valid, measured
  # memory headroom, the capped stub CPU budget, every pool observed against the stub identity,
  # and at least one digest-verified stub image. It grants Marshall placement
  # eligibility only; the controlled executor still claims no execution.
  @spec ready?(OverallsProtocol.report()) :: boolean()
  def ready?(report), do: ready?(report, read())

  @spec ready?(OverallsProtocol.report(), {:ok, t()} | :disabled | {:error, atom()}) ::
          boolean()
  def ready?(report, substrate) do
    match?({:ok, _}, substrate) and is_map(Map.get(report, :capacity)) and
      report.pools != [] and Enum.all?(report.pools, &Map.has_key?(&1, :total_bytes)) and
      Map.get(report.inventory, "images", []) != []
  end
end
