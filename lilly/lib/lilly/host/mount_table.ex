defmodule Lilly.Host.MountTable do
  @moduledoc """
  The host mount table read from `/proc/self/mountinfo`, in the shape
  `findmnt --json --list --output TARGET,SOURCE,FSTYPE,FSROOT,OPTIONS`
  prints, without spawning a utility (ADR-0176: steady-state observation
  spawns nothing).

  Lilly runs in the host mount namespace, and `mountinfo` is readable by any
  process, so this needs no privilege.
  """

  @typedoc "One mount row: target, source, fstype, fsroot and options."
  @type row :: %{String.t() => String.t()}

  @limit 32_768

  # @cc [owner:ghuntley,label:security] mount-table-matches-findmnt
  # read/0 MUST return the rows of /proc/self/mountinfo in file order, each
  # with exactly the values findmnt prints for TARGET, SOURCE, FSTYPE, FSROOT
  # and OPTIONS: octal escapes decoded; SOURCE as `source[fsroot]` when the
  # fsroot is not "/"; OPTIONS as the per-mount options followed by the
  # superblock options. A malformed line or more than 32768 rows is :error,
  # never a partial table.
  @spec read() :: {:ok, [row()]} | :error
  def read, do: read("/proc/self/mountinfo")

  @doc false
  @spec read(Path.t()) :: {:ok, [row()]} | :error
  def read(path) do
    with {:ok, body} <- File.read(path) do
      parse(body)
    else
      _ -> :error
    end
  end

  @doc false
  @spec parse(binary()) :: {:ok, [row()]} | :error
  def parse(body) do
    lines = String.split(body, "\n", trim: true)

    if length(lines) <= @limit do
      Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, rows} ->
        case row(line) do
          {:ok, row} -> {:cont, {:ok, [row | rows]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        :error -> :error
      end
    else
      :error
    end
  end

  @doc "The topmost mount whose target is exactly `path`, as `findmnt --target PATH --first-only`."
  @spec at(Path.t()) :: {:ok, row()} | :error
  def at(path) do
    with {:ok, rows} <- read(),
         [row | _] <- rows |> Enum.filter(&(&1["target"] == path)) |> Enum.reverse() do
      {:ok, row}
    else
      _ -> :error
    end
  end

  # mountinfo: id parent major:minor root target options [optional...] - fstype source super
  defp row(line) do
    with [left, right] <- String.split(line, " - ", parts: 2),
         [_id, _parent, _device, root, target, options | _optional] <- String.split(left, " "),
         [fstype, source, super] <- String.split(right, " ", parts: 3),
         {:ok, root} <- unescape(root),
         {:ok, target} <- unescape(target),
         {:ok, fstype} <- unescape(fstype),
         {:ok, source} <- unescape(source),
         {:ok, super} <- unescape(super) do
      {:ok,
       %{
         "target" => target,
         "source" => if(root == "/", do: source, else: source <> "[" <> root <> "]"),
         "fstype" => fstype,
         "fsroot" => root,
         "options" => options(options, super)
       }}
    else
      _ -> :error
    end
  end

  defp options(vfs, super) do
    # findmnt merges the superblock's ro/rw into the per-mount flags: a
    # read-only superblock makes the mount read-only.
    super = String.split(super, ",", trim: true)
    vfs = String.split(vfs, ",", trim: true)

    vfs =
      if "ro" in super, do: Enum.map(vfs, &if(&1 == "rw", do: "ro", else: &1)), else: vfs

    Enum.join(vfs ++ Enum.reject(super, &(&1 in ["ro", "rw"])), ",")
  end

  # mountinfo escapes space, tab, newline and backslash as \ooo.
  defp unescape(field) do
    case Regex.split(~r/\\([0-7]{3})/, field, include_captures: true) do
      parts ->
        decoded =
          Enum.map(parts, fn
            <<"\\", digits::binary-size(3)>> = part ->
              case Integer.parse(digits, 8) do
                {value, ""} when value < 256 -> <<value>>
                _ -> part
              end

            part ->
              part
          end)

        {:ok, IO.iodata_to_binary(decoded)}
    end
  end
end
