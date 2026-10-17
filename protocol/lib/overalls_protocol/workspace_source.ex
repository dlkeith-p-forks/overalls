defmodule OverallsProtocol.WorkspaceSource do
  @moduledoc """
  Closed public repository identities. Only the guest resolves refs and clones.
  Source v2 is the sole supported schema; hosts are derived from the provider.
  """
  @type provider :: :github | :gitlab | :codeberg | :bitbucket
  @type revision ::
          %{kind: :default}
          | %{kind: :ref | :tag | :commit, value: String.t()}
          | %{kind: :change, value: pos_integer()}
  @type t :: %{
          provider: provider(),
          namespace: [String.t()],
          repository: String.t(),
          revision: revision()
        }
  @type reason ::
          :invalid_url
          | :unsupported_host
          | :invalid_namespace
          | :invalid_repository
          | :invalid_reference
  @providers [:github, :gitlab, :codeberg, :bitbucket]
  @github_owner ~r/\A[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}\z/
  @component ~r/\A[A-Za-z0-9_][A-Za-z0-9._-]{0,99}\z/
  @repository ~r/\A[A-Za-z0-9._-]{1,100}\z/
  @named_ref ~r/\A[A-Za-z0-9._\/@+=,-]{1,255}\z/
  @commit ~r/\A[0-9a-fA-F]{7,64}\z/

  # @cc [owner:ghuntley,label:security;protocol] public-workspace-source-closed-grammar
  # Only fixed HTTPS provider origins and bounded ASCII repository identities
  # MUST be accepted. Peer maps MUST have exactly the v2 fields. No namespace,
  # repository or revision may introduce git options, traversal or shell syntax.
  @spec parse_url(term()) :: {:ok, t()} | {:error, reason()}
  def parse_url(url) when is_binary(url) and byte_size(url) <= 1024 do
    stripped = url |> String.split(["?", "#"], parts: 2) |> hd()

    with true <- String.valid?(url) || {:error, :invalid_url},
         {:ok, provider, path} <- provider_path(stripped),
         parts = path |> String.trim_trailing("/") |> String.split("/"),
         {:ok, namespace, repository, rest} <- repository_path(provider, parts),
         true <- namespace?(provider, namespace) || {:error, :invalid_namespace},
         repository = String.replace_suffix(repository, ".git", ""),
         true <- repository?(repository) || {:error, :invalid_repository},
         {:ok, revision} <- revision(provider, rest) do
      {:ok,
       %{provider: provider, namespace: namespace, repository: repository, revision: revision}}
    else
      {:error, _} = error -> error
    end
  end

  def parse_url(_), do: {:error, :invalid_url}

  @spec valid?(term()) :: boolean()
  def valid?(
        %{provider: provider, namespace: namespace, repository: repository, revision: revision} =
          value
      )
      when map_size(value) == 4 do
    provider in @providers and namespace?(provider, namespace) and repository?(repository) and
      not String.ends_with?(repository, ".git") and revision?(revision) and
      not (provider == :bitbucket and revision.kind == :tag)
  end

  def valid?(_), do: false

  @spec display_name(t()) :: String.t()
  def display_name(source), do: Enum.join(source.namespace ++ [source.repository], "/")
  @spec clone_url(t()) :: String.t()
  def clone_url(source),
    do: "https://" <> host(source.provider) <> "/" <> display_name(source) <> ".git"

  @spec host(provider()) :: String.t()
  def host(:github), do: "github.com"
  def host(:gitlab), do: "gitlab.com"
  def host(:codeberg), do: "codeberg.org"
  def host(:bitbucket), do: "bitbucket.org"

  @spec to_url(t()) :: String.t()
  def to_url(source) do
    base = "https://" <> host(source.provider) <> "/" <> display_name(source)

    case {source.provider, source.revision} do
      {_, %{kind: :default}} ->
        base

      {:github, %{kind: :ref, value: value}} ->
        base <> "/tree/" <> value

      {:github, %{kind: :tag, value: value}} ->
        base <> "/releases/tag/" <> value

      {:github, %{kind: :commit, value: value}} ->
        base <> "/commit/" <> value

      {:github, %{kind: :change, value: value}} ->
        base <> "/pull/" <> Integer.to_string(value)

      {:gitlab, %{kind: :ref, value: value}} ->
        base <> "/-/tree/" <> value

      {:gitlab, %{kind: :tag, value: value}} ->
        base <> "/-/tags/" <> value

      {:gitlab, %{kind: :commit, value: value}} ->
        base <> "/-/commit/" <> value

      {:gitlab, %{kind: :change, value: value}} ->
        base <> "/-/merge_requests/" <> Integer.to_string(value)

      {:codeberg, %{kind: :ref, value: value}} ->
        base <> "/src/branch/" <> value

      {:codeberg, %{kind: :tag, value: value}} ->
        base <> "/src/tag/" <> value

      {:codeberg, %{kind: :commit, value: value}} ->
        base <> "/commit/" <> value

      {:codeberg, %{kind: :change, value: value}} ->
        base <> "/pulls/" <> Integer.to_string(value)

      {:bitbucket, %{kind: :ref, value: value}} ->
        base <> "/src/" <> value

      {:bitbucket, %{kind: :commit, value: value}} ->
        base <> "/commits/" <> value

      {:bitbucket, %{kind: :change, value: value}} ->
        base <> "/pull-requests/" <> Integer.to_string(value)
    end
  end

  @spec encode(t()) :: map()
  def encode(source) do
    revision =
      case source.revision do
        %{kind: :default} -> %{"kind" => "default"}
        %{kind: kind, value: value} -> %{"kind" => Atom.to_string(kind), "value" => value}
      end

    %{
      "version" => 2,
      "provider" => Atom.to_string(source.provider),
      "namespace" => source.namespace,
      "repository" => source.repository,
      "revision" => revision
    }
  end

  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_message}
  def decode(
        %{
          "version" => 2,
          "provider" => provider,
          "namespace" => namespace,
          "repository" => repository,
          "revision" => revision
        } = value
      )
      when map_size(value) == 5 do
    with {:ok, provider} <- provider(provider),
         {:ok, revision} <- decode_revision(revision),
         source = %{
           provider: provider,
           namespace: namespace,
           repository: repository,
           revision: revision
         },
         true <- valid?(source),
         true <- byte_size(to_url(source)) <= 1024 do
      {:ok, source}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def decode(_), do: {:error, :invalid_message}

  defp provider("github"), do: {:ok, :github}
  defp provider("gitlab"), do: {:ok, :gitlab}
  defp provider("codeberg"), do: {:ok, :codeberg}
  defp provider("bitbucket"), do: {:ok, :bitbucket}
  defp provider(_), do: :error
  defp provider_path("https://github.com/" <> path), do: {:ok, :github, path}
  defp provider_path("https://gitlab.com/" <> path), do: {:ok, :gitlab, path}
  defp provider_path("https://codeberg.org/" <> path), do: {:ok, :codeberg, path}
  defp provider_path("https://bitbucket.org/" <> path), do: {:ok, :bitbucket, path}

  defp provider_path(url) do
    if String.starts_with?(url, ["https://", "http://"]),
      do: {:error, :unsupported_host},
      else: {:error, :invalid_url}
  end

  defp repository_path(:gitlab, parts) do
    {identity, rest} = Enum.split_while(parts, &(&1 != "-"))

    case Enum.reverse(identity) do
      [repository, _ | _] -> {:ok, Enum.drop(identity, -1), repository, rest}
      _ -> {:error, :invalid_url}
    end
  end

  defp repository_path(_, [namespace, repository | rest]),
    do: {:ok, [namespace], repository, rest}

  defp repository_path(_, _), do: {:error, :invalid_url}
  defp namespace?(:github, [owner]) when is_binary(owner), do: Regex.match?(@github_owner, owner)
  defp namespace?(:github, _), do: false

  defp namespace?(provider, parts) when is_list(parts) and parts != [] do
    (provider == :gitlab or length(parts) == 1) and Enum.all?(parts, &namespace_component?/1) and
      byte_size(Enum.join(parts, "/")) <= 255
  end

  defp namespace?(_, _), do: false

  defp namespace_component?(part),
    do: is_binary(part) and Regex.match?(@component, part) and not String.contains?(part, "..")

  defp repository?(value),
    do:
      is_binary(value) and Regex.match?(@repository, value) and value not in [".", ".."] and
        not String.starts_with?(value, "-") and not String.ends_with?(value, ".git")

  defp revision(_, []), do: {:ok, %{kind: :default}}
  defp revision(:github, ["tree" | parts]), do: named(:ref, parts)
  defp revision(:github, ["releases", "tag" | parts]), do: named(:tag, parts)
  defp revision(:github, ["commit", value]), do: commit(value)

  defp revision(:github, ["pull", value | rest]),
    do: change(value, rest, ["files", "commits", "checks"])

  defp revision(:gitlab, ["-", "tree" | parts]), do: named(:ref, parts)

  defp revision(:gitlab, ["-", route | parts]) when route in ["tags", "releases"],
    do: named(:tag, parts)

  defp revision(:gitlab, ["-", "commit", value]), do: commit(value)

  defp revision(:gitlab, ["-", "merge_requests", value | rest]),
    do: change(value, rest, ["diffs", "commits", "pipelines", "changes"])

  defp revision(:codeberg, ["src", "branch" | parts]), do: named(:ref, parts)
  defp revision(:codeberg, ["src", "tag" | parts]), do: named(:tag, parts)
  defp revision(:codeberg, ["releases", "tag" | parts]), do: named(:tag, parts)

  defp revision(:codeberg, ["src", "commit", value | rest]) do
    if rest == [] or named?(Enum.join(rest, "/")),
      do: commit(value),
      else: {:error, :invalid_reference}
  end

  defp revision(:codeberg, ["commit", value]), do: commit(value)
  defp revision(:codeberg, ["pulls", value | rest]), do: change(value, rest, ["files", "commits"])
  defp revision(:bitbucket, ["src" | parts]), do: named(:ref, parts)
  defp revision(:bitbucket, ["commits", value]), do: commit(value)

  defp revision(:bitbucket, ["pull-requests", value | rest]),
    do: change(value, rest, ["diff", "commits", "activity"])

  defp revision(_, _), do: {:error, :invalid_reference}

  defp named(kind, parts) do
    value = Enum.join(parts, "/")
    if named?(value), do: {:ok, %{kind: kind, value: value}}, else: {:error, :invalid_reference}
  end

  defp commit(value) do
    if is_binary(value) and Regex.match?(@commit, value),
      do: {:ok, %{kind: :commit, value: String.downcase(value)}},
      else: {:error, :invalid_reference}
  end

  defp change(value, rest, tabs) do
    if Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, value) and String.to_integer(value) <= 2_147_483_647 and
         (rest == [] or (length(rest) == 1 and hd(rest) in tabs)),
       do: {:ok, %{kind: :change, value: String.to_integer(value)}},
       else: {:error, :invalid_reference}
  end

  defp decode_revision(%{"kind" => "default"} = value) when map_size(value) == 1,
    do: {:ok, %{kind: :default}}

  defp decode_revision(%{"kind" => kind, "value" => value} = map) when map_size(map) == 2 do
    case kind do
      "ref" -> {:ok, %{kind: :ref, value: value}}
      "tag" -> {:ok, %{kind: :tag, value: value}}
      "commit" -> {:ok, %{kind: :commit, value: value}}
      "change" -> {:ok, %{kind: :change, value: value}}
      _ -> :error
    end
  end

  defp decode_revision(_), do: :error
  defp revision?(%{kind: :default} = value), do: map_size(value) == 1

  defp revision?(%{kind: kind, value: value} = map) when kind in [:ref, :tag],
    do: map_size(map) == 2 and named?(value)

  defp revision?(%{kind: :commit, value: value} = map),
    do:
      map_size(map) == 2 and is_binary(value) and Regex.match?(@commit, value) and
        String.downcase(value) == value

  defp revision?(%{kind: :change, value: value} = map),
    do: map_size(map) == 2 and is_integer(value) and value > 0 and value <= 2_147_483_647

  defp revision?(_), do: false

  defp named?(value) when is_binary(value) do
    Regex.match?(@named_ref, value) and value != "@" and not String.contains?(value, "..") and
      not String.ends_with?(value, ".") and
      Enum.all?(String.split(value, "/"), fn part ->
        part != "" and not String.starts_with?(part, [".", "-"]) and
          not String.ends_with?(part, ".lock")
      end)
  end

  defp named?(_), do: false
end
