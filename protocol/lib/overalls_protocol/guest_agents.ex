defmodule OverallsProtocol.GuestAgents do
  @moduledoc """
  The closed table of guest agent sets an image may declare and what each set
  can do. Lilly and Marshall branch on these capabilities, never on the set name.
  """

  @type t :: :linux | :none | :windows_v1 | :windows_editor_v1 | :freebsd_v1 | :illumos_v1

  @type capabilities :: %{
          readiness: boolean(),
          trust: boolean(),
          terminal: boolean(),
          workspace: boolean(),
          inception: boolean(),
          flush: boolean(),
          ssh: boolean(),
          agents: boolean(),
          editor: boolean()
        }

  @all %{
    readiness: true,
    trust: true,
    terminal: true,
    workspace: true,
    inception: true,
    flush: true,
    ssh: true,
    agents: true,
    editor: true
  }

  @none Map.new(@all, fn {key, _} -> {key, false} end)

  # @cc [owner:ghuntley,label:protocol;security] guest-agents-capability-table-closed
  # capabilities/1 and capabilities/2 are the only authority for what a guest agent set can do. A
  # new agent set MUST be a new value with its own row. Existing rows MUST NOT
  # be widened or repurposed; a reviewed fail-closed narrowing is permitted
  # when an earlier row overclaimed an implementation that does not exist.
  # parse/1 MUST accept exactly the wire names of this table and MUST NOT create
  # atoms. Native capabilities/1 rows MUST remain false: capabilities/2 may
  # activate only an exact NativeAdmission-reviewed image or portable bundle,
  # without widening any retained stock-image identity or changing wire names.
  @spec capabilities(t()) :: capabilities()
  def capabilities(:linux), do: @all
  def capabilities(:none), do: @none
  def capabilities(:windows_v1), do: %{@all | inception: false, editor: false}
  def capabilities(:windows_editor_v1), do: %{@all | inception: false}
  # A native agent-set name alone remains fail-closed. Reviewed image context
  # is required by capabilities/2. Native transport remains
  # discoverable through vsock?/1 so the setup path cannot accidentally fall
  # back to a non-native transport.
  def capabilities(:freebsd_v1), do: @none
  def capabilities(:illumos_v1), do: @none

  # @cc [owner:ghuntley,label:security;protocol] guest-agents-native-context-required
  # Native capabilities MUST require a validated exact reviewed image or bundle
  # with the matching agent set; missing or mismatched context MUST return the
  # all-false row. Native admission MUST NOT grant editor or Inception support.
  @spec capabilities(t(), term()) :: capabilities()
  def capabilities(agents, %{guest_agents: agents} = identity)
      when agents in [:freebsd_v1, :illumos_v1] do
    if OverallsProtocol.NativeAdmission.admitted?(identity),
      do: %{@all | inception: false, editor: false},
      else: @none
  end

  # @cc [owner:ghuntley,label:security;protocol] windows-editor-context-required
  # The separate Windows editor row MUST require normalized Windows firmware,
  # x86_64, PCI and a closed EditorRelease descriptor in capabilities/2. Callers
  # MUST first validate the immutable v7 image or v4 bundle through its codec;
  # an old Windows row or a missing descriptor MUST NOT gain editor capability.
  def capabilities(:windows_editor_v1, %{
        guest_agents: :windows_editor_v1,
        os: :windows,
        boot_kind: :firmware,
        architecture: :x86_64,
        pci: true,
        editor: %{protocol: 1, commit: commit, release: release} = editor
      })
      when map_size(editor) == 3 do
    if OverallsProtocol.EditorRelease.digest?(commit, 40) and
         OverallsProtocol.EditorRelease.digest?(release, 64),
       do: capabilities(:windows_editor_v1),
       else: @none
  end

  def capabilities(:windows_editor_v1, _), do: @none
  def capabilities(agents, %{guest_agents: agents}), do: capabilities(agents)
  def capabilities(_, _), do: @none

  @spec wire(t()) :: String.t()
  def wire(:linux), do: "linux"
  def wire(:none), do: "none"
  def wire(:windows_v1), do: "windows-v1"
  def wire(:windows_editor_v1), do: "windows-editor-v1"
  def wire(:freebsd_v1), do: "freebsd-v1"
  def wire(:illumos_v1), do: "illumos-v1"

  @spec parse(term()) :: {:ok, t()} | :error
  def parse("linux"), do: {:ok, :linux}
  def parse("none"), do: {:ok, :none}
  def parse("windows-v1"), do: {:ok, :windows_v1}
  def parse("windows-editor-v1"), do: {:ok, :windows_editor_v1}
  def parse("freebsd-v1"), do: {:ok, :freebsd_v1}
  def parse("illumos-v1"), do: {:ok, :illumos_v1}
  def parse(_), do: :error

  @doc "Whether any protocol of the set is spoken over the jail vsock device."
  @spec vsock?(t()) :: boolean()
  def vsock?(agents) do
    if agents in [:freebsd_v1, :illumos_v1] do
      true
    else
      capabilities = capabilities(agents)

      capabilities.readiness or capabilities.trust or capabilities.terminal or
        capabilities.workspace or capabilities.flush
    end
  end

  # @cc [owner:ghuntley,label:recovery] readiness-budget-by-agent-set
  # readiness_budget_ms/2 MUST give every agent set a fixed readiness deadline:
  # Linux guests 120 s (Inception 2400 s for its instance-specific rebuild) and
  # firmware guests with guest agents 600 s, matching Marshall's provision
  # service level. A set without readiness has no budget to spend and MUST NOT
  # be waited for.
  @spec readiness_budget_ms(t(), atom()) :: pos_integer()
  def readiness_budget_ms(:linux, :inception), do: 2_400_000
  def readiness_budget_ms(:linux, _profile), do: 120_000
  def readiness_budget_ms(:windows_v1, _profile), do: 600_000
  def readiness_budget_ms(:windows_editor_v1, _profile), do: 600_000
  def readiness_budget_ms(:freebsd_v1, _profile), do: 600_000
  def readiness_budget_ms(:illumos_v1, _profile), do: 600_000
  def readiness_budget_ms(:none, _profile), do: 120_000
end
