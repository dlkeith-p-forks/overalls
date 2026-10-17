defmodule Lilly.Host.UIDReservation do
  @moduledoc "Reject local account and subordinate-ID overlap with the dedicated VM UID/GID range."
  @first 1_000_002
  @last 1_262_142
  # @cc [owner:ghuntley,label:security] reserved-identities-reject-local-overlap
  # check/0 MUST reject local account UID/GID or subordinate-ID overlap with the VM range,
  # including primary GIDs. Unreadable or malformed required account files must not be interpreted
  # as an unused range.
  @spec check() :: :ok | {:error, :vm_identity_range_unavailable}
  def check do
    files = [
      {"/etc/passwd", :account},
      {"/etc/group", :account},
      {"/etc/subuid", :subordinate},
      {"/etc/subgid", :subordinate}
    ]

    if Enum.all?(files, fn {path, kind} -> available_file?(path, kind) end),
      do: :ok,
      else: {:error, :vm_identity_range_unavailable}
  end

  @spec available?(binary(), :account | :subordinate) :: boolean()
  def available?(bytes, kind) when is_binary(bytes) and byte_size(bytes) <= 1_048_576 do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.all?(fn line ->
      String.starts_with?(line, "#") or valid_entry?(String.split(line, ":"), kind)
    end)
  end

  def available?(_, _), do: false

  defp available_file?(path, kind) do
    case File.lstat(path) do
      {:error, :enoent} ->
        kind == :subordinate

      {:ok, %File.Stat{type: :regular, uid: 0, size: size}} when size <= 1_048_576 ->
        case File.read(path) do
          {:ok, body} -> available?(body, kind)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_entry?([_name, _password, uid, gid, _gecos, _home, _shell], :account),
    do: available_id?(uid) and available_id?(gid)

  defp valid_entry?([_name, _password, gid, _members], :account), do: available_id?(gid)

  defp valid_entry?([_name, start, count], :subordinate) do
    with {start, ""} <- Integer.parse(start),
         {count, ""} <- Integer.parse(count),
         true <- start >= 0 and count > 0 and start + count <= 4_294_967_295,
         do: start > @last or start + count - 1 < @first,
         else: (_ -> false)
  end

  defp valid_entry?(_, _), do: false

  defp available_id?(value) do
    case Integer.parse(value) do
      {id, ""} when id in 0..4_294_967_294 -> id not in @first..@last
      _ -> false
    end
  end
end
