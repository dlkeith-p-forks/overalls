defmodule Brady.Cache.Pressure do
  @moduledoc "Fresh root-produced ZFS observations bound to this process's actual mount."
  @keys ~w(version host_id dataset device boot_id observed_ms pool_total_bytes pool_available_bytes parent_total_bytes parent_available_bytes cache_quota_bytes)
  @maximum 9_223_372_036_854_775_807

  @spec read(map()) :: {:ok, term(), map()} | {:stale, term()} | :error
  def read(config) do
    path = "/run/brady-pressure/pressure.json"

    with {:ok, dir} <- File.stat(Path.dirname(path)),
         true <- dir.type == :directory and dir.uid == 0 and Bitwise.band(dir.mode, 0o022) == 0,
         {:ok, info} <- File.lstat(path),
         true <-
           info.type == :regular and info.uid == 0 and info.links == 1 and
             Bitwise.band(info.mode, 0o022) == 0,
         {:ok, encoded} <- bounded(path, 4096),
         {:ok, value} <- JSON.decode(encoded),
         {:ok, uptime} <- bounded("/proc/uptime", 128),
         {seconds, _} <- Float.parse(uptime),
         {:ok, boot} <- bounded("/proc/sys/kernel/random/boot_id", 64),
         {:ok, mounts} <- bounded("/proc/self/mountinfo", 1_048_576) do
      validate(value, config, mounts, trunc(seconds * 1000), String.trim(boot))
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # @cc [owner:ghuntley,label:security;capacity] brady-pressure-native-binding
  # A sample MUST match this boot, configured host/dataset and the exact local
  # writable ZFS mount device. Observations older than three seconds MUST never
  # authorize writes; they may prove current mount custody only after every other
  # boot/schema/mount check passes. Future samples MUST fail. Wall-clock
  # corrections MUST NOT revive stale capacity observations.
  @spec validate(term(), map(), String.t(), integer(), String.t()) ::
          {:ok, term(), map()} | {:stale, term()} | :error
  def validate(value, config, mounts, now, boot) when is_map(value) do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@keys),
         1 <- value["version"],
         true <- value["host_id"] == config.host_id and value["dataset"] == config.cache_dataset,
         true <- value["boot_id"] == boot,
         at when is_integer(at) and at >= 0 and at <= now <-
           value["observed_ms"],
         true <-
           Enum.all?(
             ~w(pool_total_bytes pool_available_bytes parent_total_bytes parent_available_bytes cache_quota_bytes),
             fn key -> is_integer(value[key]) and value[key] >= 0 and value[key] <= @maximum end
           ),
         true <- value["pool_total_bytes"] >= 10_485_760 and value["parent_total_bytes"] > 0,
         true <- value["pool_available_bytes"] <= value["pool_total_bytes"],
         true <- value["parent_available_bytes"] <= value["parent_total_bytes"],
         quota =
           min(
             value["cache_quota_bytes"],
             min(
               Brady.Cache.Budget.defaults(value["pool_total_bytes"]).quota,
               config.limits.quota
             )
           ),
         true <- quota >= 1_048_576,
         {:ok, binding} <-
           mount(mounts, config.cache_directory, config.cache_dataset, value["device"]) do
      if at >= now - 3000 do
        {:ok, binding,
         %{
           total: value["pool_total_bytes"],
           available: value["pool_available_bytes"],
           parent_total: value["parent_total_bytes"],
           parent_available: value["parent_available_bytes"],
           quota: quota,
           deadline: System.monotonic_time(:millisecond) + at + 3000 - now
         }}
      else
        {:stale, binding}
      end
    else
      _ -> :error
    end
  end

  def validate(_, _, _, _, _), do: :error

  defp mount(text, path, dataset, device) when is_binary(device) do
    rows = String.split(text, "\n", trim: true)

    matches =
      Enum.flat_map(rows, fn row ->
        case String.split(row, " - ", parts: 2) do
          [left, right] ->
            case {String.split(left, " "), String.split(right, " ")} do
              {[id, _, ^device, "/", ^path, flags | _], ["zfs", ^dataset, _]} ->
                if "rw" in String.split(flags, ","), do: [{id, device, dataset}], else: []

              _ ->
                []
            end

          _ ->
            []
        end
      end)

    case matches do
      [binding] -> {:ok, binding}
      _ -> :error
    end
  end

  defp mount(_, _, _, _), do: :error

  defp bounded(path, maximum) do
    case File.open(path, [:read, :binary], &IO.binread(&1, maximum + 1)) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= maximum -> {:ok, bytes}
      _ -> :error
    end
  end
end
