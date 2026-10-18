# Shared by scripts/mix_security_upgrades.exs and its regression tests.
defmodule Overalls.MixSecurityUpgrades do
  @moduledoc false
  alias Overalls.DependencyPins, as: Pins
  alias Overalls.DependencyPins.Finding

  @minimum_hex Version.parse!("2.5.3")
  @advisory ~r/\A  (\S+) (\S+) - (\S+) \(([A-Za-z]+)\)\z/
  @retirement ~r/\A\s+(\S+)\s+(\S+)\s+.*?\((\w+)\)\s*(.*)\z/

  @doc "Mix projects with a lock file, relative to `root`, excluding fetched dependencies."
  @spec projects(Path.t()) :: [Path.t()]
  def projects(root) do
    ["*/mix.lock", "*/*/mix.lock"]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.map(&(&1 |> Path.dirname() |> Path.relative_to(root)))
    |> Enum.reject(&(String.contains?(&1, "deps/") or String.contains?(&1, "_build/")))
    |> Enum.sort()
  end

  @doc """
  Security findings from `mix hex.audit` output: every unignored advisory and
  every retirement whose reason is `security`. Ignored sections are skipped.
  """
  @spec parse_audit(String.t()) :: [Finding.t()]
  def parse_audit(output) do
    output
    |> Pins.strip_ansi()
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({nil, []}, &audit_line/2)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.kind, &1.package, &1.version, &1.id})
  end

  @spec audit_line(String.t(), {atom() | nil, [Finding.t()]}) :: {atom() | nil, [Finding.t()]}
  defp audit_line("Advisories:", {_, acc}), do: {:advisories, acc}
  defp audit_line("Retired:", {_, acc}), do: {:retired, acc}
  defp audit_line("Retired packages:", {_, acc}), do: {:retired, acc}
  defp audit_line("", state), do: state
  defp audit_line(<<c, _::binary>>, {_, acc}) when c not in [?\s, ?\t], do: {nil, acc}

  defp audit_line(line, {:advisories, acc}) do
    case Regex.run(@advisory, line) do
      [_, package, version, id, severity] ->
        finding = %Finding{
          kind: :advisory,
          package: package,
          version: version,
          id: id,
          severity: severity
        }

        {:advisories, [finding | acc]}

      nil ->
        {:advisories, describe(acc, line)}
    end
  end

  defp audit_line(line, {:retired, acc}) do
    case Regex.run(@retirement, line) do
      [_, package, version, "security", message] ->
        finding = %Finding{
          kind: :retirement,
          package: package,
          version: version,
          id: "retired",
          summary: message
        }

        {:retired, [finding | acc]}

      _ ->
        {:retired, acc}
    end
  end

  defp audit_line(_line, state), do: state

  # The first indented line after an advisory header that is neither an alias
  # list nor a URL is its one-line title.
  @spec describe([Finding.t()], String.t()) :: [Finding.t()]
  defp describe([%Finding{kind: :advisory, summary: nil} = finding | rest], line) do
    text = String.trim(line)

    if String.starts_with?(text, ["aka:", "http://", "https://"]),
      do: [finding | rest],
      else: [%{finding | summary: text} | rest]
  end

  defp describe(acc, _line), do: acc

  @doc "Whether the Hex archive is new enough to report security advisories."
  @spec supported_hex?(String.t()) :: boolean()
  def supported_hex?(info) do
    case Regex.run(~r/^Hex:\s+(\S+)/m, Pins.strip_ansi(info)) do
      [_, version] ->
        case Version.parse(version) do
          {:ok, parsed} -> Version.compare(parsed, @minimum_hex) != :lt
          :error -> false
        end

      nil ->
        false
    end
  end

  @spec minimum_hex() :: String.t()
  def minimum_hex, do: to_string(@minimum_hex)
end
