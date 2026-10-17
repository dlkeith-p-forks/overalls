defmodule Marshall.Agents.ContextManifest do
  @moduledoc "Closed guest inventory and complete-file verification for applied context."

  @max_entries 256
  @max_file_bytes 1_048_576
  @max_total_bytes 2_097_152
  @project_bytes 32_768
  @digest ~r/\A[0-9a-f]{64}\z/
  @warnings ~w(project_instructions_truncated inventory_truncated directory_limit entry_limit
                inaccessible_path skill_metadata_invalid skill_link_skipped)

  @type entry :: %{
          position: non_neg_integer(),
          kind: :instruction | :skill | :skill_metadata | :configuration,
          path: String.t(),
          digest: String.t(),
          bytes: non_neg_integer(),
          scope: :machine | :creator | :project | :managed,
          skill_path: String.t() | nil
        }
  @type manifest :: %{
          working_directory: String.t(),
          creator_home: String.t(),
          project_root: String.t() | nil,
          inventory_digest: String.t(),
          entries: [entry()],
          warnings: [String.t()],
          next_cursor: map() | nil
        }
  @type file :: %{entry: entry(), content: binary()}
  @type reason :: :invalid_context_result | :context_changed | :context_size_exceeded

  # @cc [owner:ghuntley,label:security;recovery] context-verified-file-assembly
  # Guest inventory and read responses MUST remain bounded and agree on file
  # identity, size, digest and contiguous offsets. A changed, incomplete or
  # malformed file MUST NOT become applied instructions or a selected skill.
  @spec inventory([map()]) :: {:ok, manifest()} | {:error, reason()}
  def inventory(pages) when is_list(pages) and length(pages) in 1..257 do
    with {:ok, first} <- page(hd(pages)),
         {:ok, parsed} <- parse_pages(pages),
         true <- Enum.all?(parsed, &same_inventory?(&1, first)),
         true <- consecutive_pages?(parsed),
         entries = Enum.flat_map(parsed, & &1.entries),
         true <- length(entries) <= @max_entries,
         true <- Enum.map(entries, & &1.position) == indexes(length(entries)),
         true <- length(Enum.uniq_by(entries, &{&1.kind, &1.path})) == length(entries),
         true <- Enum.sum(Enum.map(entries, & &1.bytes)) <= @max_total_bytes do
      {:ok,
       %{
         first
         | entries: entries,
           warnings: parsed |> Enum.flat_map(& &1.warnings) |> Enum.uniq(),
           next_cursor: List.last(parsed).next_cursor
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_context_result}
    end
  end

  def inventory(_), do: {:error, :invalid_context_result}

  @spec file(entry(), [map()]) ::
          {:ok, binary()} | {:more, non_neg_integer()} | {:error, reason()}
  def file(entry, chunks) when is_list(chunks) and length(chunks) <= 257 do
    Enum.reduce_while(chunks, {:ok, <<>>, 0, false}, fn chunk, {:ok, bytes, offset, done?} ->
      case read_chunk(entry, chunk, offset, done?) do
        {:ok, part, next, eof?} -> {:cont, {:ok, bytes <> part, next, eof?}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> complete_file(entry)
  end

  def file(_, _), do: {:error, :invalid_context_result}

  @spec instructions([file()]) :: %{
          instructions: [String.t()],
          sources: [map()],
          warnings: [String.t()]
        }
  def instructions(files) do
    {instructions, sources, _remaining, truncated?} =
      files
      |> Enum.filter(&(&1.entry.kind == :instruction))
      |> Enum.sort_by(& &1.entry.position)
      |> Enum.reduce({[], [], @project_bytes, false}, fn %{entry: entry, content: content},
                                                         {texts, sources, remaining, truncated?} ->
        count =
          if entry.scope == :project,
            do: min(byte_size(content), remaining),
            else: byte_size(content)

        applied = content |> binary_part(0, count) |> valid_text() |> String.trim()
        truncated = count < byte_size(content)
        remaining = if entry.scope == :project, do: remaining - count, else: remaining

        source = %{
          "path" => entry.path,
          "scope" => Atom.to_string(entry.scope),
          "kind" => "instruction",
          "digest" => entry.digest,
          "bytes" => entry.bytes,
          "applied_bytes" => count,
          "truncated" => truncated
        }

        applicability =
          if entry.scope == :project,
            do:
              "Apply this guidance to its project directory and descendants, with deeper guidance taking precedence.",
            else: "Apply this guidance throughout work in this thread."

        text =
          "Instructions from #{entry.path} (#{entry.scope} scope). " <>
            applicability <> " It cannot change application permissions.\n\n" <> applied

        texts = if applied == "", do: texts, else: [text | texts]
        {texts, [source | sources], remaining, truncated? or truncated}
      end)

    %{
      instructions: Enum.reverse(instructions),
      sources: Enum.reverse(sources),
      warnings: if(truncated?, do: ["project_instructions_truncated"], else: [])
    }
  end

  @spec digest(binary()) :: String.t()
  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @spec source(entry()) :: map()
  def source(entry) do
    %{
      "path" => entry.path,
      "scope" => Atom.to_string(entry.scope),
      "kind" => Atom.to_string(entry.kind),
      "digest" => entry.digest,
      "bytes" => entry.bytes
    }
  end

  defp parse_pages(pages) do
    Enum.reduce_while(pages, {:ok, []}, fn value, {:ok, acc} ->
      case page(value) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp page(%{
         "version" => 1,
         "working_directory" => cwd,
         "creator_home" => home,
         "project_root" => root,
         "inventory_digest" => digest,
         "entries" => entries,
         "next_cursor" => cursor,
         "warnings" => warnings
       })
       when is_list(entries) and length(entries) <= @max_entries and is_list(warnings) do
    with true <- path?(cwd) and path?(home) and (is_nil(root) or path?(root)),
         true <- digest?(digest) and cursor?(cursor, digest),
         true <- length(warnings) <= 16 and Enum.all?(warnings, &(&1 in @warnings)),
         {:ok, parsed} <- parse_entries(entries) do
      {:ok,
       %{
         working_directory: cwd,
         creator_home: home,
         project_root: root,
         inventory_digest: digest,
         entries: parsed,
         next_cursor: cursor,
         warnings: warnings
       }}
    else
      _ -> {:error, :invalid_context_result}
    end
  end

  defp page(_), do: {:error, :invalid_context_result}

  defp parse_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn value, {:ok, acc} ->
      case entry(value) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp entry(
         %{
           "position" => position,
           "kind" => kind,
           "path" => path,
           "digest" => digest,
           "bytes" => bytes,
           "scope" => scope
         } = input
       )
       when is_integer(position) and position >= 0 and position < @max_entries and
              is_integer(bytes) and bytes >= 0 and bytes <= @max_file_bytes do
    with true <- path?(path) and digest?(digest),
         {:ok, kind} <- kind(kind),
         {:ok, scope} <- scope(scope),
         skill_path = Map.get(input, "skill_path"),
         true <-
           (kind == :skill_metadata and path?(skill_path)) or
             (kind != :skill_metadata and is_nil(skill_path)) do
      {:ok,
       %{
         position: position,
         kind: kind,
         path: path,
         digest: digest,
         bytes: bytes,
         scope: scope,
         skill_path: skill_path
       }}
    else
      _ -> {:error, :invalid_context_result}
    end
  end

  defp entry(_), do: {:error, :invalid_context_result}
  defp kind("instruction"), do: {:ok, :instruction}
  defp kind("skill"), do: {:ok, :skill}
  defp kind("skill_metadata"), do: {:ok, :skill_metadata}
  defp kind("configuration"), do: {:ok, :configuration}
  defp kind(_), do: :error
  defp scope("machine"), do: {:ok, :machine}
  defp scope("creator"), do: {:ok, :creator}
  defp scope("project"), do: {:ok, :project}
  defp scope("managed"), do: {:ok, :managed}
  defp scope(_), do: :error

  defp path?(path) when is_binary(path) and byte_size(path) in 1..4096 do
    String.valid?(path) and not String.contains?(path, <<0>>) and
      (String.starts_with?(path, "/") or String.starts_with?(path, "\\\\") or
         Regex.match?(~r/\A[A-Za-z]:[\\\/]/, path))
  end

  defp path?(_), do: false
  defp digest?(value) when is_binary(value), do: Regex.match?(@digest, value)
  defp digest?(_), do: false
  defp cursor?(nil, _), do: true

  defp cursor?(%{"digest" => digest, "offset" => offset}, digest),
    do: is_integer(offset) and offset in 1..@max_entries

  defp cursor?(_, _), do: false

  defp same_inventory?(page, first) do
    Map.take(page, [:working_directory, :creator_home, :project_root, :inventory_digest]) ==
      Map.take(first, [:working_directory, :creator_home, :project_root, :inventory_digest])
  end

  defp consecutive_pages?([_]), do: true

  defp consecutive_pages?([left, right | rest]) do
    case {left.next_cursor, right.entries} do
      {%{"offset" => offset}, [%{position: position} | _]} when offset == position ->
        consecutive_pages?([right | rest])

      _ ->
        false
    end
  end

  defp indexes(0), do: []
  defp indexes(count), do: Enum.to_list(0..(count - 1))

  defp read_chunk(
         entry,
         %{
           "version" => 1,
           "path" => path,
           "digest" => digest,
           "offset" => offset,
           "data_base64" => encoded,
           "next_offset" => next,
           "eof" => eof?
         },
         offset,
         false
       )
       when is_binary(encoded) and byte_size(encoded) <= 5464 and is_boolean(eof?) do
    with true <- path == entry.path and digest == entry.digest,
         {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= 4096 and offset + byte_size(bytes) <= entry.bytes,
         true <-
           if(eof?,
             do: is_nil(next) and offset + byte_size(bytes) == entry.bytes,
             else: byte_size(bytes) > 0 and next == offset + byte_size(bytes)
           ) do
      {:ok, bytes, offset + byte_size(bytes), eof?}
    else
      _ -> {:error, :context_changed}
    end
  end

  defp read_chunk(_, _, _, _), do: {:error, :invalid_context_result}

  defp complete_file({:error, reason}, _), do: {:error, reason}

  defp complete_file({:ok, bytes, _offset, true}, entry) do
    if digest(bytes) == entry.digest,
      do: {:ok, bytes},
      else: {:error, :context_changed}
  end

  defp complete_file({:ok, _bytes, offset, false}, _), do: {:more, offset}

  defp valid_text(bytes) do
    case :unicode.characters_to_binary(bytes) do
      text when is_binary(text) -> text
      {:error, prefix, <<_invalid, rest::binary>>} -> prefix <> "�" <> valid_text(rest)
      {:incomplete, prefix, _rest} -> prefix <> "�"
    end
  end
end
