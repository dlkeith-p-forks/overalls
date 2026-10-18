defmodule Marshall.SSH.GuestAccess do
  @moduledoc "Fresh inner guest SSH decision after a trusted physical VM binding."
  alias Marshall.Access.Authorization
  alias Marshall.Accounts.{GuestAccount, GuestAccounts, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, Operation, PhysicalOutcome}
  alias Marshall.Ingress.Session
  alias Marshall.Inference.Credentials
  alias Marshall.SSH.{GuestLogin, Key}
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security] guest-roster-bound-current-writers
  # Roster candidates come only from current VM ownership, direct and bound
  # thread grants, and team membership. The combined distinct candidates MUST
  # retain the 512-account ceiling. Every candidate still needs a fresh Cedar
  # write decision; viewers and retired thread generations MUST NOT enter the
  # returned roster.
  @spec roster(binary(), map()) :: {:ok, map()} | {:error, term()}
  def roster(token, wire) do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.roster_binding(wire) do
      Ledger.transaction(
        fn ->
          authority = Credentials.authenticate_locked!(token)
          unless authority.host_id == binding.host_id, do: deny!()
          vm = Ledger.lock!(Marshall.Compute.VirtualMachine, binding.vm_id) || deny!()
          unless vm.profile in [:customer, :oss, :standard, :inception], do: deny!()
          bootstrap_execution!(vm, binding)
          writers = current_writers!(vm)

          accounts =
            writers
            |> GuestAccounts.ensure_all!()
            |> Enum.map(&%{username: &1.username, uid: &1.uid})

          [[version]] =
            Ecto.Adapters.SQL.query!(
              Marshall.Repo,
              "SELECT nextval('account_guest_roster_seq')",
              [],
              log: false
            ).rows

          %{version: version, accounts: accounts}
        end,
        {:provisioner, binding.host_id}
      )
    else
      _ -> {:error, :unauthorized}
    end
  end

  # @cc [owner:ghuntley,label:security] guest-authorized-keys-pull-authority
  # The pulled key list MUST be computed from the same current writers as the
  # roster, over the ordinary four-field binding of a running, started
  # execution, and MUST list for each account only that user's unarchived
  # registered keys; a deleted user, a non-writer or a stale binding yields no
  # keys. It exists for guests whose sshd cannot ask per connection (Windows,
  # ADR-0171) and never records a login.
  @spec authorized_keys(binary(), map()) :: {:ok, map()} | {:error, term()}
  def authorized_keys(token, wire) do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire) do
      Ledger.transaction(
        fn ->
          authority = Credentials.authenticate_locked!(token)
          unless authority.host_id == binding.host_id, do: deny!()
          vm = Ledger.lock!(Marshall.Compute.VirtualMachine, binding.vm_id) || deny!()
          unless vm.profile in [:customer, :oss, :standard], do: deny!()
          physical_execution!(vm, binding)
          writers = current_writers!(vm)

          accounts =
            writers
            |> GuestAccounts.ensure_all!()
            |> Enum.map(fn account ->
              keys =
                Key
                |> Ash.Query.filter(user_id == ^account.user_id and is_nil(archived_at))
                |> Ash.read!(actor: SystemActor.compute())
                |> Enum.map(& &1.public_key)
                |> Enum.sort()

              %{username: account.username, uid: account.uid, keys: keys}
            end)

          [[version]] =
            Ecto.Adapters.SQL.query!(
              Marshall.Repo,
              "SELECT nextval('account_guest_roster_seq')",
              [],
              log: false
            ).rows

          %{version: version, accounts: accounts}
        end,
        {:provisioner, binding.host_id}
      )
    else
      _ -> {:error, :unauthorized}
    end
  end

  @spec current_writers!(Marshall.Compute.VirtualMachine.t()) :: [Ash.UUID.t()]
  defp current_writers!(vm) do
    grant_ids =
      Marshall.Access.Grant
      |> Ash.Query.filter(vm_id == ^vm.id)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(& &1.user_id)

    team_ids =
      if vm.team_id do
        Marshall.Teams.TeamMember
        |> Ash.Query.filter(team_id == ^vm.team_id)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.map(& &1.user_id)
      else
        []
      end

    thread_ids = Marshall.Threads.Authorization.machine_user_ids(vm)
    candidates = Enum.uniq([vm.owner_id | grant_ids ++ team_ids ++ thread_ids])
    if length(candidates) > 512, do: deny!()

    for id <- candidates,
        user = current_user(id),
        user != nil,
        Authorization.allowed?(vm, user, "write"),
        do: id
  end

  @spec authorize(binary(), map(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  def authorize(token, wire, public_key, username) do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire),
         {:ok, parsed} <- OverallsProtocol.SSHKey.parse(public_key),
         {:ok, %{public_key: key, vm_id: vm_id, user_id: user_id, key_id: key_id}} <-
           Ledger.transaction(
             fn ->
               authority = Credentials.authenticate_locked!(token)
               unless authority.host_id == binding.host_id, do: deny!()
               decide!(binding, parsed, username)
             end,
             {:provisioner, binding.host_id}
           ) do
      unless Marshall.Repo.in_transaction?(),
        do:
          Marshall.Events.emit("ssh.guest_key_eligible",
            vm_id: vm_id,
            user_id: user_id,
            key_id: key_id
          )

      {:ok, %{public_key: key}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  # @cc [owner:ghuntley,label:security;observability] guest-login-post-auth-report
  # The PAM session hook supplies sshd's signed-key authentication info after
  # authentication. Recheck current authority and persist a guest-reported login
  # row before acknowledging the session; key probes MUST not create login rows.
  # VM root can forge this report, so the Audi outer session remains the trusted
  # connectivity audit boundary.
  @spec login(binary(), map(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  def login(token, wire, public_key, username) do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire),
         {:ok, parsed} <- OverallsProtocol.SSHKey.parse(public_key),
         {:ok, login} <-
           Ledger.transaction(
             fn ->
               authority = Credentials.authenticate_locked!(token)
               unless authority.host_id == binding.host_id, do: deny!()
               eligible = decide!(binding, parsed, username)

               Ledger.create!(GuestLogin, :record, %{
                 vm_id: eligible.vm_id,
                 user_id: eligible.user_id,
                 key_id: eligible.key_id,
                 host_id: binding.host_id,
                 placement_id: binding.placement_id,
                 execution_epoch: binding.execution_epoch
               })
             end,
             {:provisioner, binding.host_id}
           ) do
      unless Marshall.Repo.in_transaction?(),
        do:
          Marshall.Events.emit("ssh.guest_login_reported",
            vm_id: login.vm_id,
            user_id: login.user_id,
            key_id: login.key_id,
            login_id: login.id
          )

      {:ok, %{login_id: login.id}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp current_user(id) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!()
    |> case do
      %User{} = user -> user
      _ -> nil
    end
  end

  # @cc [owner:ghuntley,label:security] guest-key-fresh-session-and-cedar
  # A trusted VM binding and exact registered offered key MUST match a current
  # Audi SSH session, account username, live execution, and fresh Cedar write.
  # Failure MUST return no key. Eligibility MUST NOT be logged as a login.
  @spec authorize(map(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def authorize(wire, public_key, requested_username) do
    result =
      with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire),
           {:ok, parsed} <- OverallsProtocol.SSHKey.parse(public_key) do
        Ledger.transaction(fn -> decide!(binding, parsed, requested_username) end)
      else
        _ -> {:error, :unauthorized}
      end

    case result do
      {:ok, %{public_key: key, vm_id: vm_id, user_id: user_id, key_id: key_id}} ->
        unless Marshall.Repo.in_transaction?(),
          do:
            Marshall.Events.emit("ssh.guest_key_eligible",
              vm_id: vm_id,
              user_id: user_id,
              key_id: key_id
            )

        {:ok, key}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp decide!(binding, parsed, username) do
    key =
      Key
      |> Ash.Query.filter(fingerprint == ^parsed.fingerprint)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute()) || deny!()

    unless key.public_key == parsed.public_key, do: deny!()

    user =
      User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^key.user_id)
      |> Ash.read_one!() || deny!()

    if user.deleted_at, do: deny!()

    account =
      GuestAccount
      |> Ash.Query.filter(user_id == ^user.id and is_nil(retired_at))
      |> Ash.read_one!(actor: SystemActor.compute()) || deny!()

    unless account.username == username, do: deny!()

    vm = Authorization.live_vm!(binding.vm_id, user, "write")
    unless vm.profile in [:customer, :oss, :standard], do: deny!()
    current_execution!(vm, binding)
    active_session!(vm, binding, key)

    %{public_key: key.public_key, vm_id: vm.id, user_id: user.id, key_id: key.id}
  end

  # @cc [owner:ghuntley,label:security;recovery] guest-roster-before-relocation-readiness
  # An authenticated host's roster/certificate boot proof may precede completion of its
  # exact current start/provision/resume operation. It MUST match host, placement,
  # epoch, generation and operation and deny cancelled/failed starts. Only the
  # six-field boot binding is accepted; SSH key and login decisions MUST
  # continue to require completed execution and relocation readiness.
  @spec bootstrap_execution!(
          Marshall.Compute.VirtualMachine.t(),
          OverallsProtocol.PrivateServices.roster_binding()
        ) :: :ok
  def bootstrap_execution!(vm, %{operation_id: id, generation: generation} = binding) do
    current_host!(vm, binding)
    unless vm.generation == generation, do: deny!()
    operation = Ledger.read!(Operation, id: id) |> List.first() || deny!()

    unless operation.vm_id == vm.id and operation.placement_id == vm.current_placement_id and
             operation.execution_epoch == vm.execution_epoch and
             operation.generation == generation and
             operation.kind in [:provision, :start, :resume],
           do: deny!()

    case operation.status do
      status when status in [:pending, :acknowledged] ->
        :ok

      :completed ->
        unless vm.observed_state == :running and successful_start?(operation, binding),
          do: deny!()

      _ ->
        deny!()
    end

    :ok
  end

  defp successful_start?(operation, binding) do
    with [outcome] <- Ledger.read!(PhysicalOutcome, id: operation.completion_outcome_id),
         {:ok, evidence} <- OverallsProtocol.Execution.outcome(outcome.observation) do
      outcome.host_id == binding.host_id and evidence.operation_id == operation.id and
        evidence.vm_id == binding.vm_id and evidence.placement_id == binding.placement_id and
        evidence.execution_epoch == binding.execution_epoch and
        evidence.generation == binding.generation and
        evidence.state == :running and evidence.disk_present and not evidence.compute_empty
    else
      _ -> false
    end
  end

  defp current_execution!(vm, binding) do
    physical_execution!(vm, binding)

    unless Marshall.Compute.RelocationReadinessState.terminal_allowed?(vm), do: deny!()
  end

  defp physical_execution!(vm, binding) do
    current_host!(vm, binding)
    unless vm.observed_state == :running, do: deny!()

    started =
      Operation
      |> Ash.Query.filter(
        vm_id == ^vm.id and placement_id == ^vm.current_placement_id and
          execution_epoch == ^vm.execution_epoch and generation == ^vm.generation and
          status == :completed and kind in [:provision, :start, :resume]
      )
      |> Ash.exists?(actor: SystemActor.compute())

    unless started, do: deny!()
  end

  defp current_host!(vm, binding) do
    host = Ledger.read!(Host, id: binding.host_id) |> List.first() || deny!()

    unless host.enabled and host.maintenance_mode != :retired and
             is_binary(host.connection_session_id) and
             Marshall.Compute.HostLiveness.authority?(
               host.connection_session_id,
               host.reported_at,
               Ledger.now()
             ) and
             vm.host_id == host.id and vm.current_placement_id == binding.placement_id and
             vm.execution_epoch == binding.execution_epoch and vm.desired_state == :running and
             is_nil(vm.archived_at),
           do: deny!()
  end

  defp active_session!(vm, binding, key) do
    now = Ledger.now()

    current =
      Session
      |> Ash.Query.filter(
        key_id == ^key.id and vm_id == ^vm.id and host_id == ^binding.host_id and
          placement_id == ^binding.placement_id and
          execution_epoch == ^binding.execution_epoch and generation == ^vm.generation and
          is_nil(closed_at) and expires_at > ^now
      )
      |> Ash.exists?(actor: SystemActor.compute())

    unless current, do: deny!()
  end

  defp deny!, do: Ledger.rollback(:unauthorized)
end
