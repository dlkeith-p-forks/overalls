defmodule Marshall.Editor.Releases do
  @moduledoc "Closed target-specific editor release admission; configured packages grant no user authority."
  alias OverallsProtocol.{EditorRelease, ImageManifest}

  @type target :: :linux_x64 | :win32_x64
  @type t :: %{optional(target()) => EditorRelease.t()}
  @type sql_row :: %{
          target: String.t(),
          protocol: pos_integer(),
          commit: String.t(),
          release: String.t()
        }

  # @cc [owner:ghuntley,label:security;protocol] editor-release-registry-closed
  # decode/1 MUST accept only version 1 with finite linux-x64/win32-x64 target
  # keys and closed EditorRelease values. Unknown fields/targets and duplicate
  # release digests MUST refuse. An empty registry disables all editor targets.
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_editor_releases}
  def decode(%{"version" => 1, "targets" => targets} = value)
      when map_size(value) == 2 and is_map(targets) and map_size(targets) <= 2 do
    Enum.reduce_while(targets, {:ok, %{}}, fn {wire, value}, {:ok, releases} ->
      with {:ok, target} <- target(wire),
           {:ok, descriptor} <- EditorRelease.decode(value),
           false <- Enum.any?(releases, fn {_, other} -> other.release == descriptor.release end) do
        {:cont, {:ok, Map.put(releases, target, descriptor)}}
      else
        _ -> {:halt, {:error, :invalid_editor_releases}}
      end
    end)
  end

  def decode(_), do: {:error, :invalid_editor_releases}

  @spec configured() :: t()
  def configured do
    case decode(Application.get_env(:marshall, :ingress_editor_releases)) do
      {:ok, releases} -> releases
      _ -> %{}
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] editor-release-target-from-validated-image
  # The approved tuple MUST be selected only from a codec-validated image's
  # x86_64 kernel/Linux or firmware/Windows-editor shape. A descriptor approved
  # for another target MUST NOT authorize that image, even with the same commit.
  @spec for_image(ImageManifest.t(), t()) :: {:ok, EditorRelease.t()} | :error
  def for_image(%{architecture: :x86_64, boot_kind: :kernel, guest_agents: :linux}, releases),
    do: Map.fetch(releases, :linux_x64)

  def for_image(
        %{
          architecture: :x86_64,
          boot_kind: :firmware,
          os: :windows,
          guest_agents: :windows_editor_v1
        },
        releases
      ),
      do: Map.fetch(releases, :win32_x64)

  def for_image(_, _), do: :error

  @spec approved?(EditorRelease.t(), t()) :: boolean()
  def approved?(descriptor, releases), do: descriptor in Map.values(releases)

  @spec sql_rows(t()) :: [sql_row()]
  def sql_rows(releases) do
    Enum.map(releases, fn {target, descriptor} -> Map.put(descriptor, :target, wire(target)) end)
  end

  @spec target(term()) :: {:ok, target()} | :error
  defp target("linux-x64"), do: {:ok, :linux_x64}
  defp target("win32-x64"), do: {:ok, :win32_x64}
  defp target(_), do: :error

  @spec wire(target()) :: String.t()
  defp wire(:linux_x64), do: "linux-x64"
  defp wire(:win32_x64), do: "win32-x64"
end
