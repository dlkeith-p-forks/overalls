defmodule Marshall.Agents.Skills.Catalog do
  @moduledoc "Bounded guest skill metadata and explicit identities, without filesystem authority."

  @type source :: %{
          path: String.t(),
          digest: String.t(),
          bytes: non_neg_integer(),
          scope: String.t() | atom()
        }
  @type entry :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          path: String.t(),
          digest: String.t(),
          bytes: non_neg_integer(),
          scope: String.t(),
          allow_implicit: boolean(),
          dependencies: [String.t()],
          body: String.t()
        }
  @type error ::
          :invalid_skill
          | :invalid_metadata
          | :skill_too_large
          | :catalog_too_large
          | :skill_not_found
          | :ambiguous_skill
          | :duplicate_selection

  @max_header 32_768
  @max_body 1_048_576
  @max_catalog 100
  @max_catalog_bytes 65_536
  @scopes ~w(machine creator project managed)

  # @cc [owner:ghuntley,label:security] skill-catalog-untrusted-content
  # Skill files MUST be treated as untrusted text. Parsing MUST bound input size,
  # refuse YAML references and tags, preserve distinct source identities for
  # duplicate names, and never execute or install declared dependencies.
  @spec parse(source(), binary(), binary() | nil) :: {:ok, entry()} | {:error, error()}
  def parse(source, contents, metadata \\ nil) do
    with :ok <- valid_source(source),
         :ok <- valid_contents(contents),
         {:ok, header, body} <- split_header(contents),
         {:ok, fields} <- yaml(header),
         {:ok, extra} <- optional_metadata(metadata),
         {:ok, name} <- text_field(fields, "name", 128),
         {:ok, description} <- text_field(fields, "description", 2048),
         {:ok, implicit?} <- implicit(fields, extra),
         {:ok, dependencies} <- dependencies(extra) do
      scope = to_string(source.scope)

      {:ok,
       %{
         id: identity(scope, source.path),
         name: name,
         description: description,
         path: source.path,
         digest: source.digest,
         bytes: source.bytes,
         scope: scope,
         allow_implicit: implicit?,
         dependencies: dependencies,
         body: body
       }}
    end
  end

  @doc "Returns bounded metadata; bodies are loaded only for selected skills."
  @spec catalog([entry()]) :: {:ok, [map()]} | {:error, error()}
  def catalog(entries) when is_list(entries) do
    metadata = Enum.map(entries, &Map.delete(&1, :body))

    if length(entries) <= @max_catalog and
         byte_size(Jason.encode!(metadata)) <= @max_catalog_bytes,
       do: {:ok, metadata},
       else: {:error, :catalog_too_large}
  end

  @doc "Selects exact source identities, or names only when there is one candidate."
  @spec select([entry()], [String.t()]) :: {:ok, [entry()]} | {:error, error()}
  def select(entries, selections) when is_list(entries) and is_list(selections) do
    if length(selections) > @max_catalog do
      {:error, :catalog_too_large}
    else
      Enum.reduce_while(selections, {:ok, []}, fn selection, {:ok, chosen} ->
        case resolve(entries, selection) do
          {:ok, entry} ->
            if Enum.any?(chosen, &(&1.id == entry.id)),
              do: {:halt, {:error, :duplicate_selection}},
              else: {:cont, {:ok, chosen ++ [entry]}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  @spec identity(String.t(), String.t()) :: String.t()
  def identity(scope, path),
    do: :crypto.hash(:sha256, scope <> "\0" <> path) |> Base.encode16(case: :lower)

  @doc "Collects distinct standalone skill mentions without interpreting ordinary dollar amounts."
  @spec mentions(String.t()) :: [String.t()]
  def mentions(prompt) when is_binary(prompt) do
    Regex.scan(~r/(?:\A|\s)\$([A-Za-z_][A-Za-z0-9_-]{0,127})(?=\s|[.,!?;:]|\z)/u, prompt,
      capture: :all_but_first
    )
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.take(@max_catalog + 1)
  end

  @spec resolve([entry()], term()) :: {:ok, entry()} | {:error, error()}
  defp resolve(entries, selection) when is_binary(selection) do
    case Enum.filter(entries, &(&1.id == selection)) do
      [entry] -> {:ok, entry}
      [] -> resolve_name(entries, String.trim_leading(selection, "$"))
      _ -> {:error, :ambiguous_skill}
    end
  end

  defp resolve(_, _), do: {:error, :skill_not_found}

  @spec resolve_name([entry()], String.t()) :: {:ok, entry()} | {:error, error()}
  defp resolve_name(entries, name) do
    case Enum.filter(entries, &(&1.name == name)) do
      [entry] -> {:ok, entry}
      [] -> {:error, :skill_not_found}
      _ -> {:error, :ambiguous_skill}
    end
  end

  @spec valid_source(term()) :: :ok | {:error, error()}
  defp valid_source(%{path: path, digest: digest, bytes: bytes, scope: scope})
       when is_binary(path) and is_binary(digest) and is_integer(bytes) and bytes >= 0 do
    if byte_size(path) in 1..4096 and String.valid?(path) and
         not String.contains?(path, <<0>>) and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) and
         scope in (@scopes ++ [:machine, :creator, :project, :managed]),
       do: :ok,
       else: {:error, :invalid_skill}
  end

  defp valid_source(_), do: {:error, :invalid_skill}

  @spec valid_contents(term()) :: :ok | {:error, error()}
  defp valid_contents(contents) when is_binary(contents) and byte_size(contents) > @max_body,
    do: {:error, :skill_too_large}

  defp valid_contents(contents) when is_binary(contents) do
    if String.valid?(contents), do: :ok, else: {:error, :invalid_skill}
  end

  defp valid_contents(_), do: {:error, :invalid_skill}

  @spec split_header(binary()) :: {:ok, binary(), binary()} | {:error, error()}
  defp split_header(contents) do
    case String.split(contents, ~r/\r?\n/, parts: 2) do
      ["---", rest] ->
        case Regex.run(~r/\A(.*?)\r?\n---(?:\r?\n|\z)(.*)\z/s, rest, capture: :all_but_first) do
          [header, body] when byte_size(header) <= @max_header -> {:ok, header, body}
          _ -> {:error, :invalid_skill}
        end

      _ ->
        {:error, :invalid_skill}
    end
  end

  @spec yaml(binary()) :: {:ok, map()} | {:error, error()}
  defp yaml(text) do
    # Reject expansion/tag syntax before invoking the general YAML parser. The
    # bounded descriptive format needs neither aliases nor application tags.
    if byte_size(text) <= @max_header and String.valid?(text) and
         not Regex.match?(~r/(?:\A|[\s\[\]{},:])[&*!][^\s]*/u, text) do
      case YamlElixir.read_from_string(text) do
        {:ok, fields} when is_map(fields) -> {:ok, fields}
        _ -> {:error, :invalid_metadata}
      end
    else
      {:error, :invalid_metadata}
    end
  rescue
    _ -> {:error, :invalid_metadata}
  end

  @spec optional_metadata(binary() | nil) :: {:ok, map()} | {:error, error()}
  defp optional_metadata(nil), do: {:ok, %{}}
  defp optional_metadata(text) when is_binary(text), do: yaml(text)
  defp optional_metadata(_), do: {:error, :invalid_metadata}

  @spec text_field(map(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, error()}
  defp text_field(fields, key, limit) do
    case Map.get(fields, key) do
      value when is_binary(value) ->
        value = String.trim(value)

        if byte_size(value) in 1..limit and not String.contains?(value, <<0>>),
          do: {:ok, value},
          else: {:error, :invalid_metadata}

      _ ->
        {:error, :invalid_metadata}
    end
  end

  @spec implicit(map(), map()) :: {:ok, boolean()} | {:error, error()}
  defp implicit(fields, extra) do
    policy = Map.get(extra, "policy", Map.get(fields, "policy", %{}))

    case policy do
      %{} ->
        case Map.get(policy, "allow_implicit_invocation", true) do
          value when is_boolean(value) -> {:ok, value}
          _ -> {:error, :invalid_metadata}
        end

      _ ->
        {:error, :invalid_metadata}
    end
  end

  @spec dependencies(map()) :: {:ok, [String.t()]} | {:error, error()}
  defp dependencies(extra) do
    case Map.get(extra, "dependencies", []) do
      values when is_list(values) and length(values) <= 32 ->
        if Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..256)),
          do: {:ok, values},
          else: {:error, :invalid_metadata}

      _ ->
        {:error, :invalid_metadata}
    end
  end
end
