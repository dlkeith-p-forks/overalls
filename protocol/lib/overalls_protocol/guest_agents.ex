defmodule OverallsProtocol.GuestAgents do
  @moduledoc """
  The closed table of guest agent sets an image may declare and what each set
  can do. Lilly and Marshall branch on these capabilities, never on the set name.
  """

  @type t :: :linux | :none | :windows_v1 | :freebsd_v1 | :illumos_v1

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
  # capabilities/1 is the only authority for what a guest agent set can do. A new
  # agent set MUST be a new value with its own row; an existing row MUST NOT be
  # mutated, because recorded manifests and bundles carry the set name. parse/1
  # MUST accept exactly the wire names of this table and MUST NOT create atoms.
  @spec capabilities(t()) :: capabilities()
  def capabilities(:linux), do: @all
  def capabilities(:none), do: @none
  def capabilities(:windows_v1), do: %{@all | inception: false, editor: false}
  # Native rows remain transport declarations while the cross-built kernel,
  # complete agent closure and machine evidence are unavailable. Keep every
  # user-facing capability false so a directly registered native manifest
  # cannot earn readiness, trust, workspace, SSH, agent or terminal authority.
  def capabilities(:freebsd_v1), do: @none
  def capabilities(:illumos_v1), do: @none

  @spec wire(t()) :: String.t()
  def wire(:linux), do: "linux"
  def wire(:none), do: "none"
  def wire(:windows_v1), do: "windows-v1"
  def wire(:freebsd_v1), do: "freebsd-v1"
  def wire(:illumos_v1), do: "illumos-v1"

  @spec parse(term()) :: {:ok, t()} | :error
  def parse("linux"), do: {:ok, :linux}
  def parse("none"), do: {:ok, :none}
  def parse("windows-v1"), do: {:ok, :windows_v1}
  def parse("freebsd-v1"), do: {:ok, :freebsd_v1}
  def parse("illumos-v1"), do: {:ok, :illumos_v1}
  def parse(_), do: :error

  @doc "Whether any protocol of the set is spoken over the jail vsock device."
  @spec vsock?(t()) :: boolean()
  def vsock?(agents) do
    if agents in [:freebsd_v1, :illumos_v1] do
      # The jail must retain the host-only transport shape for native bundles,
      # even while capability admission is fail-closed.
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
  # Windows guests 600 s, matching Marshall's provision service level. A set
  # without readiness has no budget to spend and MUST NOT be waited for.
  @spec readiness_budget_ms(t(), atom()) :: pos_integer()
  def readiness_budget_ms(:linux, :inception), do: 2_400_000
  def readiness_budget_ms(:linux, _profile), do: 120_000
  def readiness_budget_ms(:windows_v1, _profile), do: 600_000
  def readiness_budget_ms(:freebsd_v1, _profile), do: 600_000
  def readiness_budget_ms(:illumos_v1, _profile), do: 600_000
  def readiness_budget_ms(:none, _profile), do: 120_000
end
