defmodule Galileo.Strip do
  @moduledoc "Segment-aligned request-path prefix removal, in the request direction only."

  # @cc [owner:ghuntley,label:security] galileo-strip-segment-aligned
  # Prefix removal MUST match whole path segments only: /api/v3 matches
  # /api/v3/users and /api/v3 but never /api/v3x/other. Paths outside the
  # prefix pass through unchanged; the root remainder keeps a leading slash.
  @spec apply(binary() | nil, binary()) :: binary()
  def apply(nil, path), do: path
  def apply(_, path) when path in ["", "*"], do: path

  def apply(prefix, path) do
    prefix_segments = segments(prefix)
    path_segments = segments(path)

    case Enum.split(path_segments, length(prefix_segments)) do
      {^prefix_segments, rest} ->
        case rest do
          [] -> "/"
          _ -> "/" <> Enum.join(rest, "/")
        end

      _ ->
        path
    end
  end

  defp segments(path), do: path |> String.split("/", trim: true)
end
