defmodule Lilly.Host.Paths do
  @moduledoc """
  Path and block-device facts read without spawning a utility (ADR-0176:
  steady-state observation spawns nothing). Both need no privilege: symlinks
  under `/dev` and the Nix store, and `/sys/class/block`, are world-readable.
  """

  @max_links 40

  # @cc [owner:ghuntley,label:security] canonical-path-matches-realpath
  # canonical/1 MUST return what `realpath --canonicalize-existing` prints
  # for an absolute path: every symlink resolved (relative targets against
  # their directory), `.` and `..` removed, every component existing. A
  # missing component, a relative input, a NUL byte or more than 40 symlinks
  # is :error.
  @spec canonical(Path.t()) :: {:ok, Path.t()} | :error
  def canonical("/" <> _ = path) do
    if String.contains?(path, <<0>>), do: :error, else: walk(components(path), [], 0)
  end

  def canonical(_path), do: :error

  defp components(path), do: String.split(path, "/", trim: true)

  defp walk([], resolved, _links), do: {:ok, join(resolved)}
  defp walk(["." | rest], resolved, links), do: walk(rest, resolved, links)
  defp walk([".." | rest], resolved, links), do: walk(rest, Enum.drop(resolved, -1), links)

  defp walk([part | rest], resolved, links) do
    candidate = join(resolved ++ [part])

    case :file.read_link_info(String.to_charlist(candidate), [:raw]) do
      {:ok, info} when elem(info, 2) == :symlink ->
        with true <- links < @max_links,
             {:ok, target} <- :file.read_link_all(String.to_charlist(candidate)) do
          target = IO.chardata_to_string(target)
          base = if String.starts_with?(target, "/"), do: [], else: resolved
          walk(components(target) ++ rest, base, links + 1)
        else
          _ -> :error
        end

      {:ok, _info} ->
        walk(rest, resolved ++ [part], links)

      _ ->
        :error
    end
  end

  defp join([]), do: "/"
  defp join(parts), do: "/" <> Enum.join(parts, "/")

  # @cc [owner:ghuntley,label:security] block-device-numbers-from-sysfs
  # device_numbers/1 MUST return the major and minor numbers of the block
  # device node `/dev/<name>` from `/sys/class/block/<name>/dev`, equal to
  # `stat --printf=%t:%T` for that node. Any other path shape, a missing
  # entry or a malformed value is :error.
  @spec device_numbers(Path.t()) :: {:ok, {non_neg_integer(), non_neg_integer()}} | :error
  def device_numbers("/dev/" <> name) do
    with true <- Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,64}\z/, name),
         {:ok, body} <- File.read(Path.join(["/sys/class/block", name, "dev"])),
         [major, minor] <- body |> String.trim_trailing("\n") |> String.split(":"),
         {major, ""} <- Integer.parse(major),
         {minor, ""} <- Integer.parse(minor) do
      {:ok, {major, minor}}
    else
      _ -> :error
    end
  end

  def device_numbers(_path), do: :error
end
