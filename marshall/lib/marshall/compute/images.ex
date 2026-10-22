defmodule Marshall.Compute.Images do
  @moduledoc "Trusted operator catalog registration. Content and minimum sizes are immutable."
  alias Marshall.Compute.{Image, Ledger}
  # @cc [owner:ghuntley,label:product] images-content-identity-immutable
  # Registration MUST validate the manifest's content-derived identity before
  # writing. Re-registering that ID MUST return the existing catalog entry without
  # changing its manifest, minimum sizes, name or enabled state.
  @spec register(map(), String.t()) :: {:ok, Image.t()} | {:error, term()}
  def register(manifest, name) do
    with {:ok, image} <- OverallsProtocol.ImageManifest.validate(manifest) do
      Ledger.transaction(fn ->
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          [image.id],
          log: false
        )

        case Ledger.read!(Image, id: image.id) do
          [] -> Ledger.create!(Image, :register, %{manifest: manifest, name: name})
          [existing] -> existing
        end
      end)
    end
  end

  # @cc [owner:ghuntley,label:product;capacity] images-durable-launch-minima
  # Launch sizing MUST come from the durable enabled catalog entry, never from a
  # host's transient inventory observation, so a replayed launch derives the same
  # request shape. Disabled or unknown images are unavailable.
  @spec enabled(String.t()) ::
          {:ok,
           %{
             id: String.t(),
             minimum_memory_bytes: pos_integer(),
             minimum_disk_bytes: pos_integer()
           }}
          | {:error, :image_unavailable}
  def enabled(id) when is_binary(id) do
    case Ledger.read!(Image, id: id, enabled: true) do
      [image] -> {:ok, Map.take(image, [:id, :minimum_memory_bytes, :minimum_disk_bytes])}
      [] -> {:error, :image_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:product;capacity] images-pre-admission-size-check
  # check_requirements/2 MUST evaluate a requested size against the durable
  # enabled catalog entry with Image.requirements_met?/2, the same rule admission
  # enforces. Unknown or disabled images are unavailable. It is an early refusal
  # only: admission MUST still enforce the rule transactionally.
  @spec check_requirements(term(), Image.size_request()) ::
          :ok | {:error, :image_unavailable | :image_requirements_not_met}
  def check_requirements(id, request) when is_binary(id) do
    case Ledger.read!(Image, id: id, enabled: true) do
      [image] ->
        if Image.requirements_met?(image, request),
          do: :ok,
          else: {:error, :image_requirements_not_met}

      [] ->
        {:error, :image_unavailable}
    end
  end

  def check_requirements(_, _), do: {:error, :image_unavailable}

  # @cc [owner:ghuntley,label:security] images-guest-capabilities-by-id
  # guest_capabilities/1 MUST derive the capabilities from the durable catalog
  # row's validated manifest and MUST return all-false for an unknown ID, so every
  # terminal, agent and SSH refusal reads one authority.
  @spec guest_capabilities(term()) :: Image.guest_capabilities()
  def guest_capabilities(id) when is_binary(id) do
    case Ledger.read!(Image, id: id) do
      [image] -> Image.guest_capabilities(image)
      _ -> Image.guest_capabilities(nil)
    end
  end

  def guest_capabilities(_), do: Image.guest_capabilities(nil)

  @doc "Whether the enabled durable image can receive a repository source."
  @spec workspace_source_capable?(term()) :: boolean()
  def workspace_source_capable?(id) when is_binary(id) do
    case Ledger.read!(Image, id: id, enabled: true) do
      [image] -> Image.workspace_source_capable?(image)
      _ -> false
    end
  end

  def workspace_source_capable?(_), do: false

  # @cc [owner:ghuntley,label:capacity;security] images-readiness-budget-row-bound
  # readiness_budget_ms/2 MUST read the durable image row and return nil for an
  # unknown ID, so readiness deadlines cannot be selected by a peer-provided set.
  @spec readiness_budget_ms(term(), atom()) :: pos_integer() | nil
  def readiness_budget_ms(id, profile) when is_binary(id) and is_atom(profile) do
    case Ledger.read!(Image, id: id) do
      [image] -> Image.readiness_budget_ms(image, profile)
      _ -> nil
    end
  end

  def readiness_budget_ms(_, _), do: nil

  @doc "The guest operating system family agents should be told about."
  # @cc [owner:ghuntley,label:product] images-guest-platform-by-id
  # guest_platform/1 MUST be :windows exactly when the catalog row's validated
  # manifest declares windows-v1 or windows-editor-v1, and :unix otherwise (including
  # unknown or invalid images); it grants no authority.
  @spec guest_platform(term()) :: :unix | :windows
  def guest_platform(id) when is_binary(id) do
    with [image] <- Ledger.read!(Image, id: id),
         {:ok, agents} when agents in [:windows_v1, :windows_editor_v1] <-
           Image.guest_agents_capability(image) do
      :windows
    else
      _ -> :unix
    end
  end

  def guest_platform(_), do: :unix
end
