defmodule Marshall.Artifacts.Paths do
  @moduledoc "Normalization of artifact-relative file paths and their served media types."

  @page "index.html"
  @max_path 512
  @max_segment 255

  # Closed allowlist keyed by extension. Anything else is served as an
  # attachment of application/octet-stream.
  @types %{
    "html" => "text/html; charset=utf-8",
    "htm" => "text/html; charset=utf-8",
    "md" => "text/markdown; charset=utf-8",
    "css" => "text/css; charset=utf-8",
    "js" => "text/javascript; charset=utf-8",
    "mjs" => "text/javascript; charset=utf-8",
    "json" => "application/json",
    "txt" => "text/plain; charset=utf-8",
    "csv" => "text/csv; charset=utf-8",
    "svg" => "image/svg+xml",
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "gif" => "image/gif",
    "webp" => "image/webp",
    "avif" => "image/avif",
    "ico" => "image/x-icon",
    "woff" => "font/woff",
    "woff2" => "font/woff2",
    "ttf" => "font/ttf",
    "otf" => "font/otf",
    "mp3" => "audio/mpeg",
    "ogg" => "audio/ogg",
    "wav" => "audio/wav",
    "mp4" => "video/mp4",
    "webm" => "video/webm"
  }

  @spec page() :: String.t()
  def page, do: @page

  # @cc [owner:ghuntley,label:security] artifact-path-normalized
  # Stored paths MUST be relative, slash-separated, free of empty, `.` and `..`
  # segments, backslashes, control characters and NUL, at most 512 bytes, and
  # MUST NOT start with a reserved `__` segment. Normalization is idempotent.
  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_path}
  def normalize(path) when is_binary(path) and byte_size(path) in 1..@max_path do
    segments = path |> String.trim_leading("./") |> String.split("/")

    if String.valid?(path) and not String.contains?(path, ["\\", <<0>>]) and
         not String.starts_with?(path, "/") and
         Enum.all?(segments, &segment?/1) and not String.starts_with?(hd(segments), "__") do
      {:ok, Enum.join(segments, "/")}
    else
      {:error, :invalid_path}
    end
  end

  def normalize(_), do: {:error, :invalid_path}

  defp segment?(segment) do
    segment not in ["", ".", ".."] and byte_size(segment) <= @max_segment and
      not String.match?(segment, ~r/[\x00-\x1f\x7f]/u)
  end

  @doc "The served type for a stored path: `{media_type, disposition}`."
  @spec media_type(String.t()) :: {String.t(), :inline | :attachment}
  def media_type(path) when is_binary(path) do
    case Map.fetch(@types, extension(path)) do
      {:ok, type} -> {type, :inline}
      :error -> {"application/octet-stream", :attachment}
    end
  end

  @doc "True when an agent-declared content type agrees with the allowlist for the path."
  @spec declared_type_ok?(String.t(), String.t() | nil) :: boolean()
  def declared_type_ok?(_path, nil), do: true

  def declared_type_ok?(path, declared) when is_binary(declared) do
    {served, _} = media_type(path)
    base(served) == base(declared)
  end

  def declared_type_ok?(_, _), do: false

  @spec extension(String.t()) :: String.t()
  defp extension(path) do
    case Path.extname(path) do
      "." <> ext -> String.downcase(ext)
      _ -> ""
    end
  end

  defp base(type), do: type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
end
