defmodule OverallsProtocol.WorkspaceSourceTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.{Execution, WorkspaceSource}

  # Shared with Lyra's Rust parser so both sides refuse and accept the same URLs.
  @vectors Path.expand("../../lyra/tests/fixtures/workspace_sources.json", __DIR__)
  @external_resource @vectors
  @id "0d9cc041-9db2-4e4c-b28b-1e41d7f472c1"

  @spec vectors() :: map()
  defp vectors, do: @vectors |> File.read!() |> JSON.decode!()

  test "shared vectors accept and refuse the same URLs as the guest and CLI parsers" do
    %{"version" => 2, "accepted" => accepted, "refused" => refused} = vectors()

    for %{"url" => url, "source" => expected} <- accepted do
      assert {:ok, source} = WorkspaceSource.parse_url(url), url
      assert WorkspaceSource.encode(source) == expected
    end

    for %{"url" => url, "reason" => reason} <- refused do
      assert {:error, actual} = WorkspaceSource.parse_url(url), url
      assert Atom.to_string(actual) == reason, url
    end
  end

  property "canonical URLs and wire encodings round-trip" do
    check all(source <- source()) do
      assert WorkspaceSource.valid?(source)
      assert {:ok, ^source} = source |> WorkspaceSource.to_url() |> WorkspaceSource.parse_url()
      assert {:ok, ^source} = source |> WorkspaceSource.encode() |> WorkspaceSource.decode()
      encoded = source |> WorkspaceSource.encode() |> JSON.encode!() |> JSON.decode!()
      assert {:ok, ^source} = WorkspaceSource.decode(encoded)
    end
  end

  property "accepted sources never yield an option-shaped or traversing git argument" do
    check all(url <- url_like(), max_runs: 500) do
      case WorkspaceSource.parse_url(url) do
        {:ok, source} ->
          for value <- source.namespace ++ [source.repository, source.revision[:value]],
              is_binary(value) do
            refute String.starts_with?(value, "-")
            refute String.contains?(value, [" ", "\\", ";", "$", "`", "\n", "%"])
            refute Enum.any?(String.split(value, "/"), &(&1 in [".", ".."]))
          end

          if is_binary(source.revision[:value]),
            do: refute(String.contains?(source.revision.value, ".."))

        {:error, reason} ->
          assert reason in [
                   :invalid_url,
                   :unsupported_host,
                   :invalid_namespace,
                   :invalid_repository,
                   :invalid_reference
                 ]
      end
    end
  end

  property "decode refuses altered, extended or unversioned wire references" do
    check all(
            source <- source(),
            field <- member_of(["version", "provider", "namespace", "repository", "revision"]),
            value <- one_of([integer(), constant("-x"), constant("a b"), constant(%{})])
          ) do
      wire = WorkspaceSource.encode(source)
      assert {:error, :invalid_message} = WorkspaceSource.decode(Map.put(wire, "extra", 1))
      assert {:error, :invalid_message} = WorkspaceSource.decode(Map.delete(wire, field))
      changed = Map.put(wire, field, value)
      if changed != wire, do: assert({:error, :invalid_message} = WorkspaceSource.decode(changed))
      assert {:error, :invalid_message} = WorkspaceSource.decode(Map.put(wire, "version", 1))

      assert {:error, :invalid_message} =
               WorkspaceSource.decode(Map.put(wire, "host", "gitlab.com"))
    end
  end

  property "execution commands carry a source only for egress profiles on provision or start" do
    check all(
            source <- source(),
            kind <- member_of([:provision, :start, :stop, :delete]),
            profile <- member_of([:customer, :standard, :oss, :inception]),
            owned <- boolean()
          ) do
      command = %{command() | kind: kind, profile: profile}
      command = if owned, do: Map.put(command, :owner_id, @id), else: command
      sourced = Map.put(command, :workspace_source, source)
      wire = Execution.encode_command(sourced)

      if kind in [:provision, :start] and profile != :customer do
        assert {:ok, ^sourced} = Execution.command(wire)
        assert {:ok, [^sourced]} = Execution.commands([wire |> JSON.encode!() |> JSON.decode!()])
      else
        assert {:error, :invalid_message} = Execution.command(wire)
      end

      assert {:ok, ^command} = command |> Execution.encode_command() |> Execution.command()

      nested = put_in(wire, ["workspace_source", "path"], "/etc")
      assert {:error, :invalid_message} = Execution.command(nested)
    end
  end

  defp source do
    gen all(
          provider <- member_of([:github, :gitlab, :codeberg, :bitbucket]),
          owner <- owner(),
          repo <- repo(),
          revision <-
            one_of([
              constant(%{kind: :default}),
              map(branch(), &%{kind: :ref, value: &1}),
              map(string(Enum.concat(?0..?9, ?a..?f), length: 40), &%{kind: :commit, value: &1}),
              map(integer(1..2_147_483_647), &%{kind: :change, value: &1})
            ])
        ) do
      %{provider: provider, namespace: [owner], repository: repo, revision: revision}
    end
  end

  defp owner do
    gen all(
          head <- string(:alphanumeric, length: 1),
          parts <- list_of(string(:alphanumeric, min_length: 1, max_length: 4), max_length: 4),
          dash <- boolean()
        ) do
      joiner = if dash, do: "-", else: ""
      String.slice(Enum.join([head | parts], joiner), 0, 39) |> String.trim_trailing("-")
    end
  end

  defp repo do
    gen all(
          head <- string(:alphanumeric, length: 1),
          tail <- string(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?., ?_, ?-]]), max_length: 30)
        ) do
      strip_git(head <> tail)
    end
  end

  defp strip_git(repo) do
    if String.ends_with?(repo, ".git"),
      do: repo |> String.replace_suffix(".git", "") |> strip_git(),
      else: repo
  end

  defp branch do
    component =
      gen all(
            head <- string(:alphanumeric, length: 1),
            tail <- string(Enum.concat([?a..?z, ?0..?9, [?_, ?-, ?+, ?=, ?,, ?@]]), max_length: 8)
          ) do
        head <> tail
      end

    gen all(parts <- list_of(component, min_length: 1, max_length: 4)) do
      branch = Enum.join(parts, "/")
      # A 40-hex tree reference is a commit; keep generated branches unambiguous.
      if Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, branch), do: "b" <> branch, else: branch
    end
  end

  defp url_like do
    fragments = [
      "https://github.com/",
      "http://github.com/",
      "https://gitlab.com/",
      "o",
      "r",
      "/",
      "-",
      "..",
      "tree/",
      "commit/",
      "pull/",
      "7",
      "abc1234",
      ".git",
      "%20",
      ";",
      "$(x)",
      "@",
      "@{",
      ".lock",
      "?",
      "#",
      " ",
      "\n"
    ]

    gen(all(parts <- list_of(member_of(fragments), max_length: 12)), do: Enum.join(parts))
  end

  defp command do
    %{
      id: @id,
      owner_id: @id,
      vm_id: @id,
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      generation: 1,
      kind: :provision,
      architecture: :x86_64,
      profile: :oss,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2
    }
  end
end
