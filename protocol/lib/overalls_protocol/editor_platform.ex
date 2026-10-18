defmodule OverallsProtocol.EditorPlatform do
  @moduledoc """
  Closed identity for a platform-specific browser-editor artifact.

  This descriptor is a typed planning boundary for future platform editor
  images. It is not part of an image manifest and does not grant editor
  capability; image admission remains owned by `ImageManifest` and
  `GuestAgents`.
  """

  alias OverallsProtocol.EditorRelease

  @type os :: :linux | :windows | :freebsd | :illumos
  @type architecture :: :x86_64
  @type service_manager :: :systemd | :windows_service | :rc_d | :smf
  @type t :: %{
          version: 1,
          os: os(),
          architecture: architecture(),
          service_manager: service_manager(),
          release: EditorRelease.t()
        }

  # @cc [owner:ghuntley,label:protocol;security] editor-platform-descriptor-closed
  # decode/1 MUST accept only the version-1 platform/editor descriptor with a
  # finite OS, architecture, service-manager pairing and validated editor
  # release. Unknown fields, peer strings and mismatched service managers MUST
  # be refused without creating atoms or granting image capability.
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_editor_platform}
  def decode(
        %{
          "version" => 1,
          "os" => os,
          "architecture" => "x86_64",
          "service_manager" => service_manager,
          "release" => release
        } = value
      )
      when map_size(value) == 5 do
    with {:ok, os} <- parse_os(os),
         {:ok, service_manager} <- parse_service_manager(os, service_manager),
         {:ok, release} <- EditorRelease.decode(release) do
      {:ok,
       %{
         version: 1,
         os: os,
         architecture: :x86_64,
         service_manager: service_manager,
         release: release
       }}
    else
      _ -> {:error, :invalid_editor_platform}
    end
  end

  def decode(_), do: {:error, :invalid_editor_platform}

  # @cc [owner:ghuntley,label:protocol] editor-platform-descriptor-encoding
  # encode/1 MUST emit the exact closed wire shape for a descriptor that has
  # already passed decode/1. It MUST NOT be used as validation of peer input.
  @spec encode(t()) :: map()
  def encode(%{
        version: 1,
        os: os,
        architecture: :x86_64,
        service_manager: service_manager,
        release: release
      }) do
    %{
      "version" => 1,
      "os" => wire_os(os),
      "architecture" => "x86_64",
      "service_manager" => wire_service_manager(service_manager),
      "release" => %{
        "protocol" => release.protocol,
        "commit" => release.commit,
        "release" => release.release
      }
    }
  end

  @spec parse_os(term()) :: {:ok, os()} | {:error, :invalid_editor_platform}
  def parse_os("linux"), do: {:ok, :linux}
  def parse_os("windows"), do: {:ok, :windows}
  def parse_os("freebsd"), do: {:ok, :freebsd}
  def parse_os("illumos"), do: {:ok, :illumos}
  def parse_os(_), do: {:error, :invalid_editor_platform}

  @spec parse_service_manager(os(), term()) ::
          {:ok, service_manager()} | {:error, :invalid_editor_platform}
  def parse_service_manager(:linux, "systemd"), do: {:ok, :systemd}
  def parse_service_manager(:windows, "windows-service"), do: {:ok, :windows_service}
  def parse_service_manager(:freebsd, "rc.d"), do: {:ok, :rc_d}
  def parse_service_manager(:illumos, "smf"), do: {:ok, :smf}
  def parse_service_manager(_, _), do: {:error, :invalid_editor_platform}

  defp wire_os(:linux), do: "linux"
  defp wire_os(:windows), do: "windows"
  defp wire_os(:freebsd), do: "freebsd"
  defp wire_os(:illumos), do: "illumos"

  defp wire_service_manager(:systemd), do: "systemd"
  defp wire_service_manager(:windows_service), do: "windows-service"
  defp wire_service_manager(:rc_d), do: "rc.d"
  defp wire_service_manager(:smf), do: "smf"
end
