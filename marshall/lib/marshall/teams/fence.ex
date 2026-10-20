defmodule Marshall.Teams.Fence do
  @moduledoc """
  Native team mutation fence for SCIM-authoritative installations (ADR-0229).

  While SCIM is enabled no native team may be created or changed. A team whose
  management mode is not `:native` is locked to native mutation whatever the
  current SCIM state, so disabling SCIM leaves SCIM-managed teams locked until
  an administrator handoff, and retiring native teams cannot regain authority.
  """
  alias Marshall.Compute.Ledger
  alias Marshall.Teams.Team

  @typedoc "Why a native team mutation is refused, or `:open`."
  @type state :: :open | :scim_enabled | :scim_managed

  @doc "Whether native team creation is currently admitted."
  @spec creation_open?() :: boolean()
  def creation_open?, do: not Marshall.Scim.enabled?()

  # @cc [owner:ghuntley,label:security] team-native-mutation-fence
  # Native creation, membership, invitation and ownership-transfer mutations
  # MUST refuse while SCIM is enabled, and MUST refuse for every team whose
  # management mode is not :native even after SCIM is disabled.
  @doc "The native mutation state of `team` under the current SCIM configuration."
  @spec state(Team.t() | %{management_mode: Team.management_mode()}) :: state()
  def state(%{management_mode: :native}),
    do: if(Marshall.Scim.enabled?(), do: :scim_enabled, else: :open)

  def state(%{management_mode: _managed}), do: :scim_managed

  @doc "Whether native membership and ownership changes are admitted for `team`."
  @spec native_mutable?(Team.t() | %{management_mode: Team.management_mode()}) :: boolean()
  def native_mutable?(team), do: state(team) == :open

  @doc "Roll back the surrounding Ledger transaction unless `team` is natively mutable."
  @spec require_native!(Team.t()) :: :ok
  def require_native!(team) do
    if native_mutable?(team), do: :ok, else: Ledger.rollback(:scim_managed)
  end

  @doc "Roll back the surrounding Ledger transaction unless native creation is admitted."
  @spec require_creation_open!() :: :ok
  def require_creation_open! do
    if creation_open?(), do: :ok, else: Ledger.rollback(:scim_managed)
  end

  # @cc [owner:ghuntley,label:security] team-retiring-resources-closed
  # A retiring or handoff-pending team MUST NOT gain new team machines or team
  # integrations; its existing resources are retired by TeamRetirementWorker.
  @doc """
  Roll back with `:forbidden` unless `team` may still gain team-owned machines
  or integrations. The existing closed refusal keeps admission diagnostics and
  transport classification unchanged.
  """
  @spec require_resources_open!(Team.t()) :: :ok
  def require_resources_open!(%{management_mode: mode})
      when mode in [:retiring, :handoff_pending],
      do: Ledger.rollback(:forbidden)

  def require_resources_open!(_team), do: :ok
end
