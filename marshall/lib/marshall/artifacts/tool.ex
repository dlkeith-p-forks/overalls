defmodule Marshall.Artifacts.Tool do
  @moduledoc """
  The model's `artifact` tool: publish, read, list and delete versioned pages
  with the authority of the user who prompted the turn.
  """
  @behaviour Marshall.Agents.ServerTool

  alias Marshall.Artifacts.{Library, Limits, Paths, Publisher, Staging}

  @read_window 49_152
  @max_files 255
  @max_edits 64
  @max_guest_path 4096

  defmodule Request do
    @moduledoc "A validated `artifact` tool call."
    @enforce_keys [:operation]
    defstruct [
      :operation,
      :artifact_id,
      :base_version,
      :title,
      :description,
      :format,
      :page,
      :version,
      :path,
      :query,
      :cursor,
      :limit,
      offset: 0,
      files: %{}
    ]

    @type page ::
            {:content, binary()}
            | {:edits, [%{old_str: String.t(), new_str: String.t()}]}
            | {:stage, String.t()}
            | :keep
    @type file ::
            {:bytes, binary(), String.t() | nil} | {:stage, String.t(), String.t() | nil} | nil
    @type t :: %__MODULE__{
            operation: :publish | :read | :list | :delete,
            artifact_id: Ecto.UUID.t() | nil,
            base_version: non_neg_integer() | nil,
            title: String.t() | nil,
            description: String.t() | nil,
            format: :html | :markdown | nil,
            page: page() | nil,
            files: %{String.t() => file()},
            version: pos_integer() | nil,
            path: String.t() | nil,
            offset: non_neg_integer(),
            query: String.t() | nil,
            cursor: Ecto.UUID.t() | nil,
            limit: 1..100 | nil
          }
  end

  @impl true
  def tool, do: :artifact

  @keys %{
    "publish" =>
      ~w(operation artifact_id base_version title description format content content_path edits files),
    "read" => ~w(operation artifact_id version path offset),
    "list" => ~w(operation query cursor limit),
    "delete" => ~w(operation artifact_id)
  }

  # @cc [owner:ghuntley,label:security;protocol] artifact-tool-request
  # The artifact tool MUST accept only the closed per-operation argument sets,
  # with publish naming base_version, at most one of content, content_path and
  # edits, inline content within 128 KiB, at most 64 non-empty edits and 255
  # files, and only absolute guest paths for staged sources. The same parser
  # validates the model response and the executed command.
  @impl true
  @spec parse(term()) :: {:ok, Request.t()} | {:error, :invalid_arguments}
  def parse(%{"operation" => operation} = arguments) when is_map_key(@keys, operation) do
    if Map.keys(arguments) -- Map.fetch!(@keys, operation) == [] do
      case build(operation, arguments) do
        {:ok, request} -> {:ok, request}
        _ -> {:error, :invalid_arguments}
      end
    else
      {:error, :invalid_arguments}
    end
  end

  def parse(_), do: {:error, :invalid_arguments}

  defp build("publish", args) do
    with {:ok, id} <- optional_uuid(args["artifact_id"]),
         {:ok, base} <- non_negative(args["base_version"]),
         {:ok, title} <- optional_text(args["title"], 200),
         {:ok, description} <- optional_text(args["description"], 1000),
         {:ok, format} <- format(args["format"]),
         {:ok, page} <- page(args),
         {:ok, files} <- files(args["files"]),
         true <- valid_target?(id, base, page) do
      {:ok,
       %Request{
         operation: :publish,
         artifact_id: id,
         base_version: base,
         title: title,
         description: description,
         format: format,
         page: page,
         files: files
       }}
    end
  end

  defp build("read", args) do
    with {:ok, id} <- uuid(args["artifact_id"]),
         {:ok, version} <- optional_positive(args["version"]),
         {:ok, path} <- optional_path(args["path"]),
         {:ok, offset} <- optional_non_negative(args["offset"]) do
      {:ok,
       %Request{operation: :read, artifact_id: id, version: version, path: path, offset: offset}}
    end
  end

  defp build("list", args) do
    with {:ok, query} <- optional_text(args["query"], 256),
         {:ok, cursor} <- optional_uuid(args["cursor"]),
         {:ok, limit} <- limit(args["limit"]) do
      {:ok, %Request{operation: :list, query: query, cursor: cursor, limit: limit}}
    end
  end

  defp build("delete", args) do
    with {:ok, id} <- uuid(args["artifact_id"]),
         do: {:ok, %Request{operation: :delete, artifact_id: id}}
  end

  # A new artifact (no id) must start from base 0 with a full page.
  defp valid_target?(nil, 0, {kind, _}) when kind in [:content, :stage], do: true
  defp valid_target?(nil, _, _), do: false
  defp valid_target?(_id, _base, _page), do: true

  defp page(args) do
    case {args["content"], args["content_path"], args["edits"]} do
      {nil, nil, nil} ->
        {:ok, :keep}

      {content, nil, nil} when is_binary(content) ->
        if byte_size(content) <= Limits.inline_content_bytes(),
          do: {:ok, {:content, content}},
          else: :error

      {nil, path, nil} ->
        with {:ok, path} <- guest_path(path), do: {:ok, {:stage, path}}

      {nil, nil, edits} when is_list(edits) and length(edits) in 1..@max_edits ->
        edits
        |> Enum.reduce_while([], fn
          %{"old_str" => old, "new_str" => new} = edit, acc
          when is_binary(old) and old != "" and is_binary(new) and map_size(edit) == 2 ->
            {:cont, [%{old_str: old, new_str: new} | acc]}

          _, _ ->
            {:halt, :error}
        end)
        |> case do
          :error -> :error
          parsed -> {:ok, {:edits, Enum.reverse(parsed)}}
        end

      _ ->
        :error
    end
  end

  defp files(nil), do: {:ok, %{}}

  defp files(files) when is_map(files) and map_size(files) <= @max_files do
    Enum.reduce_while(files, {:ok, %{}}, fn {path, spec}, {:ok, acc} ->
      with {:ok, normalized} <- Paths.normalize(path),
           false <- normalized == Paths.page(),
           false <- Map.has_key?(acc, normalized),
           {:ok, file} <- file(spec) do
        {:cont, {:ok, Map.put(acc, normalized, file)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp files(_), do: :error

  defp file(nil), do: {:ok, nil}

  defp file(%{} = spec) do
    with {:ok, type} <- optional_text(spec["content_type"], 128) do
      case Map.drop(spec, ["content_type"]) do
        %{"content" => content} = only when map_size(only) == 1 and is_binary(content) ->
          if byte_size(content) <= Limits.inline_content_bytes(),
            do: {:ok, {:bytes, content, type}},
            else: :error

        %{"content_base64" => encoded} = only when map_size(only) == 1 and is_binary(encoded) ->
          with true <- byte_size(encoded) <= div(Limits.inline_content_bytes() * 4, 3) + 4,
               {:ok, bytes} <- Base.decode64(encoded),
               do: {:ok, {:bytes, bytes, type}}

        %{"source_path" => source} = only when map_size(only) == 1 ->
          with {:ok, path} <- guest_path(source), do: {:ok, {:stage, path, type}}

        _ ->
          :error
      end
    end
  end

  defp file(_), do: :error

  # Absolute Unix or drive-rooted Windows path; the guest revalidates it.
  defp guest_path(path) when is_binary(path) and byte_size(path) in 1..@max_guest_path do
    if (String.starts_with?(path, "/") or String.match?(path, ~r/\A[A-Za-z]:\\/)) and
         not String.contains?(path, <<0>>),
       do: {:ok, path},
       else: :error
  end

  defp guest_path(_), do: :error

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp uuid(_), do: :error

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: uuid(value)

  defp non_negative(value) when is_integer(value) and value >= 0 and value <= 2_147_483_647,
    do: {:ok, value}

  defp non_negative(_), do: :error

  defp optional_non_negative(nil), do: {:ok, 0}
  defp optional_non_negative(value), do: non_negative(value)

  defp optional_positive(nil), do: {:ok, nil}
  defp optional_positive(value) when is_integer(value) and value >= 1, do: non_negative(value)
  defp optional_positive(_), do: :error

  defp optional_text(nil, _max), do: {:ok, nil}

  defp optional_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)
    if String.valid?(trimmed) and byte_size(trimmed) in 1..max, do: {:ok, trimmed}, else: :error
  end

  defp optional_text(_, _), do: :error

  defp optional_path(nil), do: {:ok, nil}
  defp optional_path(path), do: Paths.normalize(path)

  defp format(nil), do: {:ok, nil}
  defp format("html"), do: {:ok, :html}
  defp format("markdown"), do: {:ok, :markdown}
  defp format(_), do: :error

  defp limit(nil), do: {:ok, nil}
  defp limit(value) when is_integer(value) and value in 1..100, do: {:ok, value}
  defp limit(_), do: :error

  @impl true
  @spec audit_kind(Request.t()) :: atom()
  def audit_kind(%Request{operation: :publish}), do: :artifact_published
  def audit_kind(%Request{operation: :read}), do: :artifact_read
  def audit_kind(%Request{operation: :list}), do: :artifact_listed
  def audit_kind(%Request{operation: :delete}), do: :artifact_deleted

  @impl true
  @spec execute(Request.t(), Marshall.Agents.ServerTool.context(), Marshall.Accounts.User.t()) ::
          Marshall.Agents.ServerTool.outcome() | :pending
  def execute(%Request{operation: :publish} = request, context, actor) do
    if Staging.staged?(request) do
      case Staging.advance(request, context, actor) do
        {:ready, publish} ->
          outcome = Publisher.publish(actor, publish)
          Staging.settle(context.command.id, outcome)
          publish_result(outcome)

        :pending ->
          :pending

        {:error, reason} ->
          {:error, reason}
      end
    else
      actor
      |> Publisher.publish(publisher_request(request, context))
      |> publish_result()
    end
  end

  def execute(%Request{operation: :read} = request, _context, actor) do
    with {:ok, artifact} <- Library.fetch(request.artifact_id, actor),
         {:ok, version} <- Library.version(artifact, request.version) do
      read_result(artifact, version, request)
    end
  end

  def execute(%Request{operation: :list} = request, _context, actor) do
    page =
      Library.list(actor, %{
        query: request.query,
        after: request.cursor,
        limit: request.limit || 20
      })

    {:ok,
     %{
       "artifacts" =>
         Enum.map(page.items, fn artifact ->
           %{
             "artifact_id" => artifact.id,
             "title" => artifact.title,
             "current_version" => artifact.current_version,
             "format" => Atom.to_string(artifact.format),
             "url" => url(artifact.id),
             "updated_at" => DateTime.to_iso8601(artifact.updated_at)
           }
         end),
       "next_cursor" => page.next_cursor
     }}
  end

  def execute(%Request{operation: :delete} = request, _context, actor) do
    with {:ok, _} <- Library.fetch(request.artifact_id, actor),
         {:ok, artifact} <- Library.delete(actor, request.artifact_id, :agent) do
      {:ok, %{"artifact_id" => artifact.id, "state" => Atom.to_string(artifact.state)}}
    end
  end

  @doc "The Publisher request for an inline publish."
  @spec publisher_request(Request.t(), Marshall.Agents.ServerTool.context()) ::
          Publisher.request()
  def publisher_request(%Request{} = request, context) do
    %{
      artifact_id: request.artifact_id,
      base_version: request.base_version,
      page: request.page,
      files: request.files,
      title: request.title,
      description: request.description,
      format: request.format,
      command_id: context.command.id,
      source_thread_id: context.user_thread && context.user_thread.id,
      via: :agent
    }
  end

  @spec publish_result({:ok, Publisher.published()} | Publisher.refusal()) ::
          Marshall.Agents.ServerTool.outcome()
  defp publish_result({:ok, %{artifact: artifact, version: version}}) do
    {:ok,
     %{
       "artifact_id" => artifact.id,
       "version" => version.number,
       "url" => url(artifact.id),
       "bytes" => version.total_bytes,
       "files" => version.file_count
     }}
  end

  defp publish_result(refusal), do: refusal

  @spec read_result(
          Marshall.Artifacts.Artifact.t(),
          Marshall.Artifacts.Version.t(),
          Request.t()
        ) :: Marshall.Agents.ServerTool.outcome()
  defp read_result(artifact, version, %Request{path: nil, offset: offset}) do
    page = Library.page(version)

    base = %{
      "artifact_id" => artifact.id,
      "title" => version.title,
      "version" => version.number,
      "current_version" => artifact.current_version,
      "format" => Atom.to_string(version.format),
      "url" => url(artifact.id),
      "files" => Enum.map(Library.files(version), &%{"path" => &1.path, "bytes" => &1.bytes})
    }

    {:ok, Map.merge(base, window(page, offset))}
  end

  defp read_result(artifact, version, %Request{path: path, offset: offset}) do
    case Enum.find(Library.files(version), &(&1.path == path)) do
      nil ->
        {:error, :not_found}

      file ->
        base = %{
          "artifact_id" => artifact.id,
          "version" => version.number,
          "path" => file.path,
          "bytes" => file.bytes,
          "content_type" => file.content_type
        }

        if text_type?(file.content_type) and file.bytes <= Limits.page_bytes(),
          do: {:ok, Map.merge(base, window(Marshall.Artifacts.Blobs.read!(file.sha256), offset))},
          else: {:ok, base}
    end
  end

  # Returns at most a window of text at a UTF-8 boundary, with the next offset.
  @spec window(binary(), non_neg_integer()) :: map()
  defp window(text, offset) when offset >= byte_size(text),
    do: %{
      "content" => "",
      "offset" => offset,
      "next_offset" => nil,
      "total_bytes" => byte_size(text)
    }

  defp window(text, offset) do
    available = byte_size(text) - offset
    slice = binary_part(text, offset, min(@read_window, available))
    slice = trim_to_valid(slice)
    next = offset + byte_size(slice)

    %{
      "content" => slice,
      "offset" => offset,
      "next_offset" => if(next < byte_size(text), do: next),
      "total_bytes" => byte_size(text)
    }
  end

  defp trim_to_valid(<<>>), do: <<>>

  defp trim_to_valid(slice) do
    if String.valid?(slice),
      do: slice,
      else: trim_to_valid(binary_part(slice, 0, byte_size(slice) - 1))
  end

  defp text_type?(type),
    do:
      String.starts_with?(type, "text/") or
        String.starts_with?(type, ["application/json", "image/svg+xml"])

  @spec url(String.t()) :: String.t()
  defp url(id), do: "/artifacts/" <> id
end
