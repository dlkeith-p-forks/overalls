defmodule FleetAccountLifecycle do
  @moduledoc "Bounded account lifecycle inputs for the sentinel-protected native fleet."
  alias Marshall.Accounts.{AuthEmail, Security, User, UserDeletion}
  alias Marshall.Compute.Ledger
  alias Marshall.Authorization.SystemActor
  require Ash.Query

  @email "retirement-invited@example.test"
  @type request :: %{required(String.t()) => String.t()}
  @type result :: %{required(atom()) => String.t() | boolean() | non_neg_integer()}

  # @cc [owner:ghuntley,label:verification;security] lifecycle-native-installed-identity
  # The invited identity MUST NOT be seeded. Bootstrap MUST complete with a
  # separate unused administrator before browser login. Fixture tokens MUST be
  # written only to private files and MUST NOT enter returned projections.
  @spec run(request()) :: result()
  def run(%{"operation" => "seed", "output" => path}) do
    Ash.Seed.seed!(User, %{email: "retirement-bootstrap@example.test", administrator: true})
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")
    Ledger.update!(bootstrap, :complete, %{})
    admin = Ash.Seed.seed!(User, %{email: "retirement-admin@example.test", administrator: true})
    survivor = Ash.Seed.seed!(User, %{email: "retirement-survivor@example.test"})

    {:ok, image} =
      Marshall.Compute.Images.register(
        System.fetch_env!("FLEET_GUEST")
        |> Path.join("manifest.json")
        |> File.read!()
        |> JSON.decode!(),
        "nixos-retirement"
      )

    strategy = AshAuthentication.Info.strategy!(User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, admin)
    private_write(path, token)
    {:ok, survivor_token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, survivor)
    private_write(path <> "-survivor", survivor_token)
    %{admin_id: admin.id, survivor_id: survivor.id, image_id: image.id}
  end

  # @cc [owner:ghuntley,label:verification;security] lifecycle-native-outbox-boundary
  # Only the isolated invited recipient's latest encrypted outbox may be opened.
  # Return metadata MUST contain no email link/token. Reading this local outbox
  # MUST NOT be described as SMTP delivery or mailbox acceptance.
  def run(%{"operation" => "outbox", "output" => path}) do
    [mail] =
      AuthEmail
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(actor: SystemActor.compute())

    %{"email" => @email, "token" => token} =
      Ash.load!(mail, :payload, actor: SystemActor.compute()).payload

    true = is_binary(token)
    private_write(path, token)
    %{written: true}
  end

  def run(%{"operation" => "stale-link", "output" => path}) do
    [_] = active_invited()
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, @email)

    private_write(path, token)
    %{written: true}
  end

  def run(%{"operation" => "share", "vm_id" => vm, "owner_id" => id}) do
    true = OverallsProtocol.uuid?(vm) and OverallsProtocol.uuid?(id)
    owner = Security.current(id)
    [invited] = active_invited()
    false = invited.administrator

    {:ok, _} =
      Marshall.Access.set_access(
        %{vm_id: vm, email: @email, role: :manager, idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    {:ok, _} = Marshall.Compute.get_vm(%{vm_id: vm}, actor: invited)
    %{shared: true, user_id: invited.id}
  end

  def run(%{"operation" => "advance", "deletion_id" => id}) do
    true = OverallsProtocol.uuid?(id)

    {:ok, outcome} =
      UserDeletion
      |> Ash.ActionInput.for_action(:advance, %{primary_key: %{"id" => id}},
        actor: SystemActor.compute()
      )
      |> Ash.run_action()

    outcome
  end

  @spec active_invited() :: [User.t()]
  defp active_invited do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(email == ^@email and is_nil(deleted_at))
    |> Ash.read!()
  end

  @spec private_write(String.t(), String.t()) :: :ok
  defp private_write(path, token) do
    true = String.starts_with?(path, "/var/lib/overalls-fleet/lifecycle-")
    {:ok, file} = File.open(path, [:write, :exclusive, :binary])

    try do
      :ok = File.chmod(path, 0o600)
      :ok = IO.binwrite(file, token)
    after
      File.close(file)
    end
  end
end
