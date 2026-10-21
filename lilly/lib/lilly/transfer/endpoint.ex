defmodule Lilly.Transfer.Endpoint do
  @moduledoc "Installed export entry points with private local configuration and no control-plane credentials."
  require Lilly.Events
  alias OverallsProtocol.{Storage, TransferSSH}
  alias Lilly.Host.{Pool, PrivateFiles}
  alias Lilly.Transfer.{ExportRequest, PermitJournal, ProbeRequest, SourceExport}

  @type config :: %{host_id: String.t(), root: Path.t(), pools: [map()]}
  @type failure :: {:error, :export_endpoint_unconfirmed}

  # @cc [owner:ghuntley,label:security] export-endpoint-config-is-local
  # load/1 MUST read a private regular local file with a closed v3 shape, canonical
  # paths and explicit bound ZFS identities (exactly id, path, filesystem_id and
  # storage per pool). It MUST NOT read control-plane
  # credentials, create journal state or inspect native storage during SSH key
  # lookup. Selected native pool identity is rechecked only when exporting.
  @spec load(Path.t()) :: {:ok, config()} | failure()
  def load(path) do
    with {:ok, bytes} <- PrivateFiles.read_secret(path),
         {:ok, %{"version" => 3, "host_id" => host, "root" => root, "pools" => pools} = wire} <-
           JSON.decode(bytes),
         true <- map_size(wire) == 4 and OverallsProtocol.uuid?(host) and path?(root),
         true <- not String.starts_with?(root, "/nix/store/"),
         true <- is_list(pools) and length(pools) in 1..64 and Enum.all?(pools, &pool?/1),
         true <- unique?(pools, & &1["id"]) and unique?(pools, & &1["storage"]["zpool_guid"]),
         true <- independent_paths?([root | Enum.map(pools, & &1["path"])]) do
      {:ok, %{host_id: host, root: root, pools: pools}}
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security] endpoint-authorize-is-not-possession
  # authorize/5 is only for root OpenSSH AuthorizedKeysCommand with server-supplied
  # account/type/key. It MUST select the dedicated account and a configured source
  # pool before returning a restricted forced command. OpenSSH still proves key
  # possession; the local channel and run/3 MUST recheck the live permit.
  @spec authorize(Path.t(), String.t(), String.t(), String.t(), Path.t()) ::
          {:ok, String.t()} | failure()
  def authorize(path, "lilly-transfer", "ssh-ed25519", encoded, executable)
      when is_binary(encoded) do
    public = "ssh-ed25519 " <> encoded
    now = System.system_time(:second)

    with true <- TransferSSH.public_key?(public),
         {:ok, config} <- load(path),
         {:ok, source} <- PermitJournal.authentication(config.root, config.host_id, public, now),
         true <- Enum.any?(config.pools, &(&1["id"] == source.pool_id)),
         {:ok, line} <-
           ExportRequest.authorized_key(config.root, config.host_id, public, executable, now) do
      {:ok, line}
    else
      _ -> rejected()
    end
  end

  def authorize(_, _, _, _, _), do: rejected()

  # @cc [owner:ghuntley,label:security;recovery] endpoint-export-rechecks-authority
  # run/3 requires the private root channel worker: encoded is the authenticated
  # key selected by SSH, stdout is its passed transport FD, and path is installed
  # configuration. It MUST select the pool through the live permit, recheck native
  # configured identity, then use serialized SourceExport supervision. Client text
  # MUST NOT choose a local path, pool, host, program or execution authority.
  # Probe requests MUST instead revalidate the probe grant and configured pool,
  # emit only its bounded challenge response, and never inspect or export storage.
  @spec run(Path.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def run(path, encoded, "lilly-probe-v3 " <> _ = command) when is_binary(encoded) do
    with {:ok, config} <- load(path),
         {:ok, request} <- ProbeRequest.parse(command),
         {:ok, grant} <-
           PermitJournal.lookup_probe(
             config.root,
             config.host_id,
             request.relocation_id,
             "ssh-ed25519 " <> encoded,
             request.challenge,
             System.system_time(:second)
           ),
         true <- Enum.any?(config.pools, &(&1["id"] == grant.intent.source.pool_id)) do
      IO.binwrite(:stdio, "lilly-probe-v3 " <> request.challenge <> "\n")
    else
      _ -> failure()
    end
  end

  def run(path, encoded, command) when is_binary(encoded) and is_binary(command) do
    public = "ssh-ed25519 " <> encoded

    with true <- TransferSSH.public_key?(public),
         {:ok, config} <- load(path),
         {:ok, grant} <-
           ExportRequest.lookup(
             config.root,
             config.host_id,
             public,
             command,
             System.system_time(:second)
           ),
         wire when is_map(wire) <-
           Enum.find(config.pools, &(&1["id"] == grant.descriptor.source.pool_id)),
         {:ok, pool} <-
           Pool.new(wire["id"], wire["path"], wire["filesystem_id"],
             host_id: config.host_id,
             storage: wire["storage"]
           ) do
      SourceExport.run(config.root, pool, public, command)
    else
      _ -> failure()
    end
  end

  def run(_, _, _), do: failure()

  @doc "Listener startup validation; no journal creation or native export."
  @spec check_main(Path.t()) :: no_return()
  def check_main(path) do
    case load(path) do
      {:ok, _} -> System.halt(0)
      _ -> System.halt(1)
    end
  rescue
    _ -> System.halt(1)
  catch
    _, _ -> System.halt(1)
  end

  @doc "Fixed release entry point; local channel supplies only bounded key/request data."
  @spec export_main(Path.t()) :: no_return()
  def export_main(path) do
    result = run(path, System.get_env("LILLY_EXPORT_KEY"), System.get_env("LILLY_EXPORT_REQUEST"))
    halt_export(result)
  rescue
    _ -> halt_export({:error, :export_worker_exception})
  catch
    _, _ -> halt_export({:error, :export_worker_exception})
  end

  # @cc [owner:ghuntley,label:security;observability] export-status-keeps-data-channel-private
  # Only :ok may produce status zero. Failures MUST log a fixed event and an
  # allowlisted reason through the configured stderr logger, never stdout or
  # inspected failure payloads. Classification MUST NOT change export authority.
  @doc false
  @spec export_status(term()) :: 0 | 1
  def export_status(:ok), do: 0

  def export_status(result) do
    reason =
      case result do
        {:error, reason}
        when reason in [
               :storage_busy,
               :export_endpoint_unconfirmed,
               :export_permit_unconfirmed,
               :source_snapshot_unconfirmed,
               :export_worker_exception,
               :invalid_exporter,
               :exporter_unavailable,
               :exporter_lock_held,
               :exporter_busy,
               :exporter_failed,
               :exporter_expired,
               :exporter_diagnostics_limit,
               :exporter_revoked,
               :exporter_unconfirmed
             ] ->
          reason

        _ ->
          :export_unconfirmed
      end

    Lilly.Events.emit("lilly.transfer_export_failed", reason: reason)

    1
  end

  @spec halt_export(term()) :: no_return()
  defp halt_export(result) do
    halt_status(export_status(result))
  end

  @doc "Fixed root AuthorizedKeysCommand entry point; stdout contains only an authorized-key line."
  @spec authorize_main(Path.t(), Path.t()) :: no_return()
  def authorize_main(path, executable) do
    case authorize(
           path,
           System.get_env("LILLY_SSH_USER"),
           System.get_env("LILLY_SSH_TYPE"),
           System.get_env("LILLY_SSH_KEY"),
           executable
         ) do
      {:ok, line} ->
        IO.binwrite(:stdio, line)
        halt_status(0)

      _ ->
        halt_status(1)
    end
  rescue
    _ -> halt_status(1)
  catch
    _, _ -> halt_status(1)
  end

  @spec halt_status(0 | 1) :: no_return()
  defp halt_status(status) do
    Logger.flush()
    System.halt(status)
  end

  # @cc [owner:ghuntley,label:security;observability] authorize-rejection-event-is-minimal
  # AuthorizedKeysCommand rejections MUST emit only a reason through the
  # catalogued effect-failure event: deliberately no key material, account,
  # path or request payloads, because this channel is reachable from any SSH
  # client. Rejection diagnostics MUST NOT change authorization outcomes. The
  # release entry point MUST flush queued events before halting.
  defp rejected do
    Lilly.Events.emit("lilly.transfer_effect_failed", reason: :export_endpoint_unconfirmed)
    failure()
  end

  defp pool?(
         %{
           "id" => id,
           "path" => path,
           "filesystem_id" => fs,
           "storage" => storage
         } = pool
       )
       when map_size(pool) == 4 do
    with true <- OverallsProtocol.uuid?(id) and path?(path),
         {:ok, identity} <- Storage.identity(storage) do
      fs == Storage.filesystem_id(identity)
    else
      _ -> false
    end
  end

  defp pool?(_), do: false
  defp unique?(values, key), do: length(Enum.uniq_by(values, key)) == length(values)

  defp path?(value) when is_binary(value),
    do:
      Regex.match?(~r/\A\/[a-zA-Z0-9_.\/-]+\z/, value) and value != "/" and
        Path.expand(value) == value

  defp path?(_), do: false

  defp independent_paths?(paths) do
    Enum.with_index(paths)
    |> Enum.all?(fn {a, index} ->
      Enum.drop(paths, index + 1)
      |> Enum.all?(fn b ->
        a != b and not String.starts_with?(a, b <> "/") and not String.starts_with?(b, a <> "/")
      end)
    end)
  end

  defp failure, do: {:error, :export_endpoint_unconfirmed}
end
