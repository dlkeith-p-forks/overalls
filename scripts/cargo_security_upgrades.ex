# Shared by scripts/cargo_security_upgrades.exs and its regression tests.
defmodule Overalls.CargoSecurityUpgrades do
  @moduledoc false
  alias Overalls.DependencyPins.Finding

  @doc "Tracked Cargo.lock paths from NUL-separated `git ls-files -z` output."
  @spec lock_paths(String.t()) :: [Path.t()]
  def lock_paths(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.filter(&(Path.basename(&1) == "Cargo.lock"))
    |> Enum.sort()
  end

  @doc """
  Vulnerabilities from `cargo audit --json`. Informational warnings
  (unmaintained, unsound, yanked) are not security advisories and are skipped.
  """
  @spec parse_audit(String.t()) :: {:ok, [Finding.t()]} | {:error, String.t()}
  def parse_audit(json) do
    with {:ok, %{"vulnerabilities" => %{"list" => list}}} when is_list(list) <- JSON.decode(json) do
      Enum.reduce_while(list, {:ok, []}, fn
        %{
          "advisory" => %{"id" => id, "title" => title},
          "package" => %{"name" => name, "version" => version}
        },
        {:ok, acc}
        when is_binary(id) and is_binary(title) and is_binary(name) and is_binary(version) ->
          {:cont,
           {:ok,
            [
              %Finding{kind: :advisory, package: name, version: version, id: id, summary: title}
              | acc
            ]}}

        _, _ ->
          {:halt, {:error, "unexpected cargo audit vulnerability entry"}}
      end)
      |> case do
        {:ok, findings} ->
          {:ok, findings |> Enum.reverse() |> Enum.uniq_by(&{&1.package, &1.version, &1.id})}

        error ->
          error
      end
    else
      _ -> {:error, "cargo audit did not produce a vulnerabilities report"}
    end
  end

  @doc "`cargo update` package specs; `name@version` disambiguates duplicate crates."
  @spec update_specs([Finding.t()]) :: [String.t()]
  def update_specs(findings) do
    findings
    |> Enum.map(&"#{&1.package}@#{&1.version}")
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&["--package", &1])
  end
end
