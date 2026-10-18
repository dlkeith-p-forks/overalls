defmodule Marshall.SSH.Commands do
  @moduledoc "Authenticated command dispatch and transactional, pinned request receipts."
  use Ash.Resource.Actions.Implementation
  alias OverallsProtocol.SSHCommand
  alias Marshall.{Access, Compute, SSH}

  alias Marshall.Compute.{
    Image,
    Ledger,
    Operation,
    PhysicalOutcome,
    Relocation,
    RelocationRetry,
    RelocationStatus,
    VirtualMachine
  }

  alias Marshall.SSH.{Authority, Request}
  require Marshall.Events

  @impl true
  def run(input, _, _) do
    with {:ok, command} <- SSHCommand.validate(input.arguments.command) do
      result =
        Ledger.transaction(fn ->
          Authority.with_actor!(
            input.arguments.gateway_token,
            input.arguments.session_token,
            fn actor, session ->
              dispatch(command, actor, session)
            end,
            SSHCommand.mutation?(command.command) or command.command == "whoami"
          )
        end)
        |> SSH.Error.result()

      # @cc [owner:ghuntley,label:observability] ssh-log-after-outer-commit
      # Admission diagnostics MUST follow the outer receipt/domain commit and
      # MUST NOT contain raw command input or user-controlled request identifiers.
      if match?({:ok, _}, result) and not Marshall.Repo.in_transaction?(),
        do: Marshall.Events.emit("ssh.command_admitted", [])

      result
    else
      _ -> {:error, SSH.Error.exception(reason: :invalid_command)}
    end
  end

  defp dispatch(command, actor, session) do
    if SSHCommand.mutation?(command.command) do
      mutate(command, actor)
    else
      case command do
        %{command: "whoami"} ->
          key =
            Ledger.read!(SSH.Key, id: session.key_id) |> List.first() ||
              Ledger.rollback(:unauthorized)

          # @cc [owner:ghuntley,label:security;persistence] discovery-allocated-guest-name
          # Authenticated whoami MUST resolve and, if needed, durably allocate
          # this current actor's guest identity. Repeats MUST return its stored
          # name; deriving the email base would advertise a retired home.
          account = guest_identity!(actor)

          %{
            version: 1,
            status: "succeeded",
            result: %{
              id: actor.id,
              email: to_string(actor.email),
              guest_username: account.username,
              public_key: key.public_key
            }
          }

        %{command: "request show", arguments: [id]} ->
          request!(id, actor) |> receipt(actor)

        _ ->
          %{version: 1, status: "succeeded", result: json(read(command, actor))}
      end
    end
  end

  @spec guest_identity!(Marshall.Accounts.User.t()) :: Marshall.Accounts.GuestAccount.t()
  defp guest_identity!(actor) do
    case Ledger.transaction(fn -> Marshall.Accounts.GuestAccounts.ensure!(actor.id) end, actor) do
      {:ok, account} -> account
      {:error, reason} -> Marshall.Repo.rollback(reason)
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] ssh-request-atomic-pinned-replay
  # Receipt creation and the domain mutation/job MUST commit in one transaction.
  # A same-user retry MUST compare semantic inputs before returning pinned results,
  # without resolving names, image defaults or recipients again. Presentation/wait
  # options MUST NOT change operation identity. Different inputs MUST conflict.
  defp mutate(command, actor) do
    id = Map.get(command.options, "request-id", Ash.UUID.generate())

    semantic =
      %{
        command
        | options:
            Map.drop(command.options, ["request-id", "json", "timeout", "no-wait"])
            |> canonical_source()
            |> redact_secrets()
      }
      |> json()

    case Ledger.read!(Request, user_id: actor.id, request_id: id) do
      [existing] ->
        if existing.command != semantic, do: Ledger.rollback(:idempotency_conflict)
        receipt(existing, actor)

      [] ->
        # Database time precedes the mutation: synchronous cancellation evidence
        # must not fall outside its newly created receipt's measurement window.
        measurement_started_at = Ledger.now()
        execution = command |> perform(actor, Ash.UUID.generate()) |> execution()

        request =
          Ledger.create!(Request, :record, %{
            request_id: id,
            measurement_started_at: measurement_started_at,
            user_id: actor.id,
            command: semantic,
            vm_id: execution.vm_id,
            operation_id: execution.operation_id,
            clone_request_id: execution.clone_request_id,
            relocation_id: execution.relocation_id,
            relocation_retry_id: execution.relocation_retry_id,
            resize_request_id: execution.resize_request_id,
            wake_request_id: execution.wake_request_id,
            status: if(execution.physical?, do: :accepted, else: :succeeded),
            result: json(execution.result)
          })

        # The mutation's action has already authorized admission; sharing may
        # deliberately revoke this actor's access, and key removal may revoke
        # this session. Subsequent calls must authorize from current state.
        envelope(request)
    end
  end

  defp read(%{command: "help", arguments: args}, _) do
    name = Enum.join(args, " ")

    %{
      commands: Enum.filter(SSHCommand.catalog(), &(name == "" or &1.name == name)),
      docs: "/docs"
    }
  end

  defp read(%{command: "images"}, actor),
    do: Compute.catalog(%{}, actor: actor) |> unwrap!() |> Map.take([:images])

  # @cc [owner:ghuntley,label:protocol] ssh-machine-workspace-status-private
  # ls/show MUST preserve their public machine response fields without exposing
  # the workspace-only editor_image_status presentation field. They expose the
  # caller's own `pinned` flag and a canonical `route` link (ADR-0222).
  defp read(%{command: "ls", options: opts}, actor) do
    page = Compute.list_vms(%{after: opts["after"]}, actor: actor) |> unwrap!()
    Map.update!(page, :items, &Enum.map(&1, fn vm -> machine_wire_view(vm) end))
  end

  defp read(%{command: "show", arguments: [ref]}, actor),
    do: resolve!(ref, actor) |> machine_wire_view()

  # @cc [owner:ghuntley,label:protocol;security] ssh-share-display-time-zone-private
  # share show MUST preserve its owner, grant and cursor fields without the
  # browser-only saved time_zone added by the sharing projection (ADR-0195).
  defp read(%{command: "share show", arguments: [ref], options: opts}, actor) do
    vm = resolve!(ref, actor)

    Access.list_grants(%{vm_id: vm.id, after: opts["after"]}, actor: actor)
    |> unwrap!()
    |> Map.update!(:owner, &Map.delete(&1, :time_zone))
    |> Map.update!(:items, &Enum.map(&1, fn grant -> Map.delete(grant, :time_zone) end))
  end

  defp read(%{command: "ssh-key list"}, actor),
    do: %{keys: SSH.list_keys(%{}, actor: actor) |> unwrap!()}

  # @cc [owner:ghuntley,label:protocol;security] ssh-integration-list-object
  # Integration listings MUST return an object containing redacted items and an
  # exclusive next_cursor, including an empty page. The domain's array result
  # MUST NOT escape as Porsche's map-only successful command result.
  defp read(%{command: "integration list", options: opts}, actor) do
    rows =
      Marshall.Galileo.list_integrations(%{after: opts["after"], limit: 51}, actor: actor)
      |> unwrap!()

    listing(rows)
  end

  defp read(%{command: "integration show", arguments: [name]}, actor),
    do: Marshall.Galileo.show_integration(%{name: name}, actor: actor) |> unwrap!()

  defp read(%{command: "team list", options: opts}, actor) do
    Marshall.Teams.list_teams(%{after: opts["after"], limit: 51}, actor: actor)
    |> unwrap!()
    |> listing()
  end

  # @cc [owner:ghuntley,label:protocol;security] ssh-team-display-time-zone-private
  # team show MUST retain its members envelope and each member's identity,
  # email and role without the browser-only saved time_zone (ADR-0195).
  defp read(%{command: "team show", arguments: [team]}, actor),
    do:
      Marshall.Teams.list_team_members(
        %{team_id: Marshall.Teams.Coordinator.resolve!(team).id},
        actor: actor
      )
      |> unwrap!()
      |> Enum.map(&Map.delete(&1, :time_zone))
      |> then(&%{members: &1})

  defp read(%{command: "exit"}, _), do: %{closed: true}

  @spec listing([map()]) :: %{items: [map()], next_cursor: binary() | nil}
  defp listing(rows) do
    items = Enum.take(rows, 50)
    cursor = if length(rows) > 50, do: List.last(items).id
    %{items: items, next_cursor: cursor}
  end

  defp perform(%{command: "clone", arguments: [ref], options: opts}, actor, key) do
    vm = resolve!(ref, actor)

    request =
      Compute.clone(%{vm_id: vm.id, name: opts["name"], idempotency_key: key}, actor: actor)
      |> unwrap!()

    {request, vm.id, nil, request.id}
  end

  # @cc [owner:ghuntley,label:security;capacity;recovery] ssh-resize-domain-authority
  # Porsche resize MUST resolve only the machine and delegate sizes, generation
  # fencing, capacity holds and manage authorization to `Compute.resize/2`; an
  # omitted option keeps the current size and a request without any size change
  # is refused as invalid_vm_size. The receipt pins the resize request and
  # follows its phases; retry and cancel go through the domain actions.
  defp perform(%{command: "resize", arguments: [ref], options: opts}, actor, key) do
    vm = resolve!(ref, actor)

    unless Enum.any?(["cpu", "memory", "disk"], &Map.has_key?(opts, &1)),
      do: Ledger.rollback(:invalid_vm_size)

    request =
      Compute.resize(
        %{
          vm_id: vm.id,
          expected_generation: vm.generation,
          idempotency_key: key,
          vcpu: integer(opts, "cpu", vm.vcpu),
          memory_bytes: size(opts, "memory", vm.memory_bytes, 1_048_576),
          disk_bytes: size(opts, "disk", vm.disk_bytes, 1_073_741_824)
        },
        actor: actor
      )
      |> unwrap!()

    %{result: resize_result(vm, request), vm_id: vm.id, resize_request_id: request.id}
  end

  # @cc [owner:ghuntley,label:security;capacity;recovery] ssh-relocation-domain-authority
  # Porsche relocation MUST resolve only the machine, then delegate automatic
  # destination selection and current manage authorization to `Compute.relocate/2`.
  # Its receipt MUST pin the returned relocation; no gateway value may select a
  # host, placement or transfer strategy, and replay MUST NOT reserve again.
  defp perform(%{command: "relocate", arguments: [ref]}, actor, key) do
    vm = resolve!(ref, actor)

    relocation =
      Compute.relocate(%{vm_id: vm.id, idempotency_key: key}, actor: actor)
      |> unwrap!()

    %{
      result: relocation_result(vm, relocation),
      vm_id: vm.id,
      relocation_id: relocation.id
    }
  end

  defp perform(%{command: command, arguments: [id]}, actor, key)
       when command in ["request retry", "request cancel"] do
    original = request!(id, actor)

    cond do
      original.clone_request_id ->
        action = if command == "request retry", do: :retry_clone, else: :cancel_clone

        result =
          apply(Compute, action, [%{request_id: original.clone_request_id}, [actor: actor]])
          |> unwrap!()

        {result, original.vm_id, nil, original.clone_request_id}

      original.relocation_id && original.command["command"] == "relocate" ->
        control_relocation(command, original, actor, key)

      original.resize_request_id && original.command["command"] == "resize" ->
        control_resize(command, original, actor)

      true ->
        Ledger.rollback(:invalid_command)
    end
  end

  # @cc [owner:ghuntley,label:product;security] ssh-new-default-profile
  # An omitted --profile MUST select OSS for Porsche creation. An explicit
  # supported profile, including Customer, MUST retain the caller's choice.

  # @cc [owner:ghuntley,label:security;product] porsche-new-source-oss-only
  # `new --source` MUST re-parse the closed provider grammar and refuse a profile
  # without egress (explicit Customer) before resolving images or admitting
  # capacity. The canonical source joins the pinned receipt's semantic inputs, so
  # a replay with another source under one request id conflicts (ADR-0128).
  defp perform(%{command: "new", options: opts}, actor, key) do
    profile =
      Map.fetch!(
        %{
          "customer" => :customer,
          "standard" => :standard,
          "oss" => :oss,
          "inception" => :inception
        },
        opts["profile"] || "oss"
      )

    source = workspace_source!(opts["source"], profile)

    default_image =
      if profile == :inception,
        do: Marshall.Compute.Profiles.inception_image_id(),
        else: Application.get_env(:marshall, :default_image_id)

    image_id = opts["image"] || default_image
    unless is_binary(image_id), do: Ledger.rollback(:image_unavailable)

    image =
      case Ledger.read!(Image, id: image_id, enabled: true) do
        [image] -> image
        [] -> Ledger.rollback(:image_unavailable)
      end

    defaults =
      Marshall.Compute.Profiles.default_shape(profile, %{
        minimum_memory_bytes: image.minimum_memory_bytes,
        minimum_disk_bytes: image.minimum_disk_bytes
      })

    request = %{
      name: opts["name"],
      team_id: team_id(opts),
      idempotency_key: key,
      image_id: image.id,
      architecture: image.architecture,
      profile: profile,
      vcpu: integer(opts, "cpu", defaults.vcpu),
      memory_bytes: size(opts, "memory", defaults.memory_bytes, 1_048_576),
      disk_bytes: size(opts, "disk", defaults.disk_bytes, 1_073_741_824)
    }

    request = if source, do: Map.put(request, :workspace_source, source), else: request

    unless OverallsProtocol.VMShape.valid?(
             request.vcpu,
             request.memory_bytes,
             request.disk_bytes
           ),
           do: Ledger.rollback(:invalid_vm_size)

    vm = Compute.provision(request, actor: actor) |> unwrap!()

    [operation] =
      Ledger.read!(Operation,
        vm_id: vm.id,
        placement_id: vm.current_placement_id,
        generation: vm.generation
      )

    result =
      vm
      |> Map.take([:id, :name, :image_id, :profile, :vcpu, :memory_bytes, :disk_bytes])
      |> Map.put(:ssh_host, Marshall.Compute.Views.ssh_host_name(vm))

    result =
      if source,
        do: Map.put(result, :workspace_source, OverallsProtocol.WorkspaceSource.to_url(source)),
        else: result

    {result, vm.id, operation.id}
  end

  defp perform(%{command: command, arguments: [ref]}, actor, key)
       when command in ["start", "stop", "pause", "resume", "unpause", "rm"] do
    vm = resolve!(ref, actor)

    kind =
      Map.fetch!(
        %{
          "start" => :start,
          "stop" => :stop,
          "pause" => :pause,
          "resume" => :resume,
          "unpause" => :resume,
          "rm" => :delete
        },
        command
      )

    operation =
      Compute.lifecycle(%{vm_id: vm.id, kind: kind, idempotency_key: key}, actor: actor)
      |> unwrap!()

    case operation do
      %Marshall.Compute.WakeRequest{} ->
        %{result: %{id: vm.id, name: vm.name}, vm_id: vm.id, wake_request_id: operation.id}

      %Operation{} ->
        {%{id: vm.id, name: vm.name}, vm.id, operation.id}
    end
  end

  # @cc [owner:ghuntley,label:product] ssh-pin-commands-idempotent
  # `pin`/`unpin` MUST resolve the machine like `rm`, call the Access pin
  # coordinator with the current SSH actor and succeed without a physical
  # operation. Repeating either MUST succeed with the same `pinned` result; a
  # refusal MUST keep the coordinator's closed reason (`pin_limit`, `machine_failed`, `vm_deleted`,
  # `forbidden`). The reply MUST carry only the machine id/name and pin state.
  defp perform(%{command: command, arguments: [ref]}, actor, _key)
       when command in ["pin", "unpin"] do
    vm = resolve!(ref, actor)

    pin =
      if command == "pin",
        do: Access.pin_machine(%{vm_id: vm.id}, actor: actor) |> unwrap!(),
        else: Access.unpin_machine(%{vm_id: vm.id}, actor: actor) |> unwrap!()

    {%{id: vm.id, name: vm.name, pinned: pin.state == :pinned}, vm.id, nil}
  end

  defp perform(%{command: command, arguments: [ref, email | rest]}, actor, key)
       when command in ["share add", "share remove"] do
    vm = resolve!(ref, actor)

    role =
      if command == "share remove",
        do: :revoked,
        else:
          Map.fetch!(
            %{"viewer" => :viewer, "operator" => :operator, "manager" => :manager},
            hd(rest)
          )

    change =
      Access.set_access(%{vm_id: vm.id, email: email, role: role, idempotency_key: key},
        actor: actor
      )
      |> unwrap!()

    {Map.take(change, [:vm_id, :user_id, :role]), vm.id, nil}
  end

  defp perform(%{command: "ssh-key remove", arguments: [id]}, actor, _key),
    do: {SSH.remove_key(%{id: id}, actor: actor) |> unwrap!(), nil, nil}

  # @cc [owner:ghuntley,label:security] ssh-integration-secrets-never-retained
  # Secret-bearing command options MUST be reduced to digests inside the
  # pinned receipt and MUST never appear in results or logs. Idempotent replay
  # compares the digests, so the same secret replays and any changed secret
  # with the same digest shape conflicts only under the same request id.
  defp perform(%{command: "integration add", arguments: [name], options: opts}, actor, key) do
    headers = header_specs(opts)

    integration =
      Marshall.Galileo.configure_integration(
        %{
          name: name,
          target: opts["target"],
          strip_prefix: opts["strip-prefix"],
          headers: headers,
          peer: Map.get(opts, "peer", false),
          peer_vm_id: peer_vm_id(opts, actor),
          team_id: team_id(opts),
          idempotency_key: key
        },
        actor: actor
      )
      |> unwrap!()

    attachment =
      if opts["attach"] do
        vm = resolve!(opts["attach"], actor)

        Marshall.Galileo.attach_integration(%{name: name, vm_id: vm.id}, actor: actor)
        |> unwrap!()
      end

    {%{id: integration.id, name: integration.name, attached: attachment != nil}, nil, nil}
  end

  defp perform(%{command: "integration rm", arguments: [name]}, actor, _key),
    do: {Marshall.Galileo.remove_integration(%{name: name}, actor: actor) |> unwrap!(), nil, nil}

  defp perform(%{command: "integration attach", arguments: [name, machine]}, actor, _key) do
    vm = resolve!(machine, actor)

    result =
      Marshall.Galileo.attach_integration(%{name: name, vm_id: vm.id}, actor: actor) |> unwrap!()

    {result, nil, nil}
  end

  defp perform(%{command: "integration detach", arguments: [name, machine]}, actor, _key) do
    vm = resolve!(machine, actor)

    result =
      Marshall.Galileo.detach_integration(%{name: name, vm_id: vm.id}, actor: actor) |> unwrap!()

    {result, nil, nil}
  end

  # @cc [owner:ghuntley,label:product;security] ssh-team-name-validation
  # The create_team action's sole invalid-name argument failure MUST become the
  # fixed invalid_request response. Other Ash errors MUST retain their identity
  # so unexpected failures cannot be reclassified as bad client input.
  defp perform(%{command: "team create", arguments: [name]}, actor, key) do
    team =
      case Marshall.Teams.create_team(%{name: name, idempotency_key: key}, actor: actor) do
        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Action.InvalidArgument{field: :name}]}} ->
          Ledger.rollback(:invalid_request)

        result ->
          unwrap!(result)
      end

    {%{id: team.id, name: team.name}, nil, nil}
  end

  defp perform(%{command: "team member add", arguments: [team, email, role]}, actor, key) do
    result =
      Marshall.Teams.set_team_member(
        %{
          team_id: Marshall.Teams.Coordinator.resolve!(team).id,
          email: email,
          role: String.to_existing_atom(role),
          idempotency_key: key
        },
        actor: actor
      )
      |> unwrap!()

    {result, nil, nil}
  end

  defp perform(%{command: "team member remove", arguments: [team, email]}, actor, key) do
    result =
      Marshall.Teams.set_team_member(
        %{
          team_id: Marshall.Teams.Coordinator.resolve!(team).id,
          email: email,
          role: :removed,
          idempotency_key: key
        },
        actor: actor
      )
      |> unwrap!()

    {result, nil, nil}
  end

  defp perform(%{command: "team transfer offer", arguments: [team, email]}, actor, _key) do
    transfer =
      Marshall.Teams.Coordinator.offer(Marshall.Teams.Coordinator.resolve!(team).id, email, actor)
      |> unwrap!()

    {%{transfer_id: transfer.id, state: transfer.state}, nil, nil}
  end

  defp perform(%{command: command, arguments: [id]}, actor, _key)
       when command in ["team transfer accept", "team transfer decline", "team transfer cancel"] do
    action = String.to_existing_atom(String.replace_prefix(command, "team transfer ", ""))
    transfer = apply(Marshall.Teams.Coordinator, action, [id, actor]) |> unwrap!()
    {%{transfer_id: transfer.id, state: transfer.state}, nil, nil}
  end

  defp control_resize(command, original, actor) do
    [resize] = Ledger.read!(Marshall.Compute.ResizeRequest, id: original.resize_request_id)
    [vm] = Ledger.history!(VirtualMachine, id: resize.vm_id)

    result =
      case command do
        "request retry" ->
          Compute.retry_resize(
            %{vm_id: vm.id, request_id: resize.id, expected_generation: vm.generation},
            actor: actor
          )

        "request cancel" ->
          Compute.cancel_resize(%{vm_id: vm.id, request_id: resize.id}, actor: actor)
      end
      |> unwrap!()

    %{result: resize_result(vm, result), vm_id: vm.id, resize_request_id: resize.id}
  end

  defp resize_result(vm, request),
    do: %{
      resize_request_id: request.id,
      machine_id: vm.id,
      phase: request.phase,
      failure: request.failure,
      original_sizes: request.original_sizes,
      target_sizes: request.target_sizes,
      original_power_state: request.original_power_state
    }

  defp control_relocation("request cancel", original, actor, _key) do
    relocation =
      Compute.cancel_relocation(%{relocation_id: original.relocation_id}, actor: actor)
      |> unwrap!()

    %{
      result: relocation_result(original.result, relocation),
      vm_id: original.vm_id,
      relocation_id: relocation.id
    }
  end

  defp control_relocation("request retry", original, actor, key) do
    retry =
      Compute.retry_relocation(
        %{relocation_id: original.relocation_id, idempotency_key: key},
        actor: actor
      )
      |> unwrap!()

    [relocation] = Ledger.read!(Relocation, id: original.relocation_id)

    %{
      result: relocation_result(original.result, relocation),
      vm_id: original.vm_id,
      relocation_id: relocation.id,
      relocation_retry_id: retry.id
    }
  end

  @secret_options ~w(bearer basic header)

  @spec workspace_source!(String.t() | nil, atom()) :: OverallsProtocol.WorkspaceSource.t() | nil
  defp workspace_source!(nil, _profile), do: nil

  defp workspace_source!(url, profile) do
    source =
      case OverallsProtocol.WorkspaceSource.parse_url(url) do
        {:ok, source} -> source
        {:error, _} -> Ledger.rollback(:invalid_workspace_source)
      end

    if OverallsProtocol.ProfilePolicy.allows?(profile, :egress),
      do: source,
      else: Ledger.rollback(:workspace_source_not_allowed)
  end

  # Equivalent provider URL spellings (trailing slash, .git, pull tabs) replay as one request.
  @spec canonical_source(map()) :: map()
  defp canonical_source(%{"source" => url} = options) do
    case OverallsProtocol.WorkspaceSource.parse_url(url) do
      {:ok, source} -> Map.put(options, "source", OverallsProtocol.WorkspaceSource.to_url(source))
      {:error, _} -> options
    end
  end

  defp canonical_source(options), do: options

  # Secret-bearing options persist only as salted digests so receipts remain
  # replay-comparable without retaining credential material.
  defp redact_secrets(options) do
    Map.new(options, fn
      {key, value} when key in @secret_options and is_binary(value) ->
        {key, digest(value)}

      {key, values} when key in @secret_options and is_list(values) ->
        {key, Enum.map(values, &digest/1)}

      entry ->
        entry
    end)
  end

  defp digest(value) do
    "digest:" <>
      (:crypto.hash(:sha256, value)
       |> Base.encode16(case: :lower)
       |> binary_part(0, 16)) <>
      ":" <> Integer.to_string(byte_size(value))
  end

  defp header_specs(opts) do
    static =
      opts["header"]
      |> List.wrap()
      |> Enum.map(fn pair ->
        [name, value] = String.split(pair, ":", parts: 2)
        %{kind: :static, name: name, value: value}
      end)

    bearer =
      if token = opts["bearer"],
        do: [%{kind: :bearer, name: "authorization", value: token}],
        else: []

    basic =
      if credentials = opts["basic"] do
        [_, _] = String.split(credentials, ":", parts: 2)
        [%{kind: :basic, name: "authorization", value: credentials}]
      else
        []
      end

    if opts["bearer"] && opts["basic"],
      do: Marshall.Repo.rollback(:conflicting_credentials)

    static ++ bearer ++ basic
  end

  defp peer_vm_id(%{"peer" => true, "peer-vm" => ref}, actor) when is_binary(ref),
    do: resolve!(ref, actor).id

  defp peer_vm_id(_, _), do: nil

  defp team_id(%{"team" => name}) when is_binary(name),
    do: Marshall.Teams.Coordinator.resolve!(name).id

  defp team_id(_), do: nil

  defp integer(opts, key, default),
    do: if(opts[key], do: String.to_integer(opts[key]), else: default)

  defp size(opts, key, minimum, unit),
    do: integer(opts, key, div(minimum + unit - 1, unit)) * unit

  defp resolve!(ref, actor), do: Compute.resolve_vm(%{reference: ref}, actor: actor) |> unwrap!()

  # Browser-only projections (editor eligibility, guest capability booleans and
  # owner contact details) stay out of the SSH/Porsche wire format. The caller's
  # own pin and the machine's app link are public to the caller (ADR-0222).
  @spec machine_wire_view(map()) :: map()
  defp machine_wire_view(vm) do
    vm
    |> Map.drop([:editor_image_status, :guest_capabilities, :owner_email, :owner_time_zone])
    |> Map.put(:route, Marshall.AppRoutes.link({:machine, vm.id}))
  end

  defp unwrap!({:ok, value}), do: value
  # @cc [owner:ghuntley,label:product;recovery] ssh-coordinator-atom-refusals
  # Trusted coordinators' closed atom refusals MUST retain their typed reason
  # across the outer receipt transaction. Arbitrary errors MUST remain opaque.
  defp unwrap!({:error, reason}) when is_atom(reason), do: Ledger.rollback(reason)
  defp unwrap!({:error, error}), do: Marshall.Repo.rollback(error)
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp request!(id, actor) do
    case Ledger.read!(Request, user_id: actor.id, request_id: id) do
      [request] -> request
      [] -> Ledger.rollback(:request_not_found)
    end
  end

  defp receipt(request, actor) do
    request = Ledger.lock!(Request, request.id)

    if request.vm_id do
      case Ledger.history!(VirtualMachine, id: request.vm_id) do
        [vm] ->
          permission =
            if request.relocation_id || request.relocation_retry_id ||
                 request.resize_request_id || request.wake_request_id,
               do: "manage",
               else: "read"

          Access.Authorization.require!(vm, actor, permission)

        [] ->
          Ledger.rollback(:forbidden)
      end
    end

    if request.clone_request_id do
      Compute.get_clone(%{request_id: request.clone_request_id}, actor: actor) |> unwrap!()
    end

    request |> refresh() |> envelope()
  end

  # @cc [owner:ghuntley,label:recovery] ssh-request-physical-success
  # Acknowledgement MUST NOT complete a request. Success/failure MUST use the
  # operation's first applied terminal outcome, checking its immutable binding.
  # Original cancelled operations MUST be reported as superseded. An explicit
  # clone-cancel request succeeds only after the clone reaches cancelled, after
  # any admitted physical cleanup. Deletion also requires completed VM archival.

  # @cc [owner:ghuntley,label:security;recovery] ssh-relocation-receipt-terminal-evidence
  # Relocation receipts MUST require current manage permission and remain accepted
  # until the pinned relocation or retry supplies a terminal domain phase. Success
  # requires complete relocation/cancellation; retryable destination failure is
  # failed, and cancellation, deletion or retry supersession is superseded. Status
  # projection MUST omit host, placement, endpoint, key and permit data.

  # @cc [owner:ghuntley,label:recovery;security] ssh-wake-receipt-physical-readiness
  # A resume receipt MUST retain its durable wake identity while capacity is
  # unavailable or relocation is pending. It MUST succeed only when that wake
  # reaches ready, require current manage permission on every status read, and
  # never expose checkpoint storage, transfer permits or gateway credentials.
  defp refresh(%{status: :accepted, wake_request_id: id} = request) when not is_nil(id) do
    case Ledger.read!(Marshall.Compute.WakeRequest, id: id, vm_id: request.vm_id) do
      [wake] ->
        extra = %{phase: wake.status, failure: wake.failure_reason}

        case wake.status do
          :ready -> finish(request, :succeeded, extra)
          :failed -> finish(request, :failed, extra)
          :cancelled -> finish(request, :superseded, extra)
          _ -> %{request | result: Map.merge(request.result, json(extra))}
        end

      [] ->
        Ledger.rollback(:request_not_found)
    end
  end

  defp refresh(%{status: :accepted, relocation_retry_id: retry_id} = request)
       when not is_nil(retry_id) do
    [retry] = Ledger.read!(RelocationRetry, id: retry_id)
    [relocation] = Ledger.read!(Relocation, id: request.relocation_id)
    refresh_relocation(request, relocation, retry)
  end

  defp refresh(%{status: :accepted, relocation_id: id} = request) when not is_nil(id) do
    [relocation] = Ledger.read!(Relocation, id: id)
    refresh_relocation(request, relocation, nil)
  end

  defp refresh(%{status: :accepted, clone_request_id: id} = request) when not is_nil(id) do
    [clone] = Ledger.read!(Marshall.Compute.CloneRequest, id: id)
    extra = Marshall.Compute.Cloning.view(clone)

    cond do
      clone.phase == :complete ->
        finish(request, :succeeded, extra)

      clone.phase == :cancelled ->
        status =
          if request.command["command"] == "request cancel", do: :succeeded, else: :superseded

        finish(request, status, extra)

      clone.phase == :failed or clone.failure == "source_restart_failed" ->
        finish(request, :failed, extra)

      true ->
        %{request | result: json(extra)}
    end
  end

  # @cc [owner:ghuntley,label:recovery] ssh-resize-receipt-terminal-phase
  # Resize receipts stay accepted until the pinned request reaches a terminal
  # phase: complete is succeeded; cancelled is succeeded for the cancel receipt
  # and superseded for the original; a finished failure is failed. A failure
  # that is still retryable keeps the receipt accepted with the recorded phase.
  defp refresh(%{status: :accepted, resize_request_id: id} = request) when not is_nil(id) do
    [resize] = Ledger.read!(Marshall.Compute.ResizeRequest, id: id)

    extra = %{
      phase: resize.phase,
      failure: resize.failure,
      original_sizes: resize.original_sizes,
      target_sizes: resize.target_sizes
    }

    cond do
      resize.phase == :complete ->
        finish(request, :succeeded, extra)

      resize.phase == :cancelled ->
        status =
          if request.command["command"] == "request cancel", do: :succeeded, else: :superseded

        finish(request, status, extra)

      resize.finished_at != nil ->
        finish(request, :failed, extra)

      true ->
        %{request | result: json(extra)}
    end
  end

  defp refresh(%{status: :accepted, operation_id: id} = request) do
    [operation] = Ledger.read!(Operation, id: id)

    cond do
      operation.status == :cancelled ->
        finish(request, :superseded, %{})

      operation.status == :completed and operation.completion_outcome_id != nil ->
        [outcome] = Ledger.read!(PhysicalOutcome, id: operation.completion_outcome_id)

        unless outcome.operation_id == id and outcome.vm_id == request.vm_id and
                 outcome.placement_id == operation.placement_id and
                 outcome.execution_epoch == operation.execution_epoch and
                 outcome.generation == operation.generation,
               do: Ledger.rollback(:invalid_outcome)

        state = outcome.observation["state"]

        expected =
          Map.fetch!(
            %{
              provision: "running",
              start: "running",
              resume: "running",
              pause: "paused",
              stop: "stopped",
              delete: "deleted"
            },
            operation.kind
          )

        cond do
          state == "failed" ->
            finish(request, :failed, %{outcome: state, reason: outcome.observation["reason"]})

          state == expected and deletion_complete?(operation) ->
            finish(request, :succeeded, %{outcome: state})

          true ->
            request
        end

      true ->
        request
    end
  end

  defp refresh(request), do: request

  defp refresh_relocation(request, relocation, retry) do
    extra = relocation_result(request.result, relocation)

    status =
      cond do
        request.command["command"] == "request cancel" and relocation.phase == :cancelled ->
          :succeeded

        relocation.phase == :complete ->
          :succeeded

        relocation.phase in [:readiness_failed, :activation_failed] ->
          :failed

        relocation.phase in [:cancelled, :deleted] ->
          :superseded

        retry != nil and retry.status == :superseded ->
          :superseded

        true ->
          nil
      end

    if status, do: finish(request, status, extra), else: %{request | result: json(extra)}
  end

  defp relocation_result(machine, relocation) do
    identity = %{
      id: Map.get(machine, :id) || Map.get(machine, "id"),
      name: Map.get(machine, :name) || Map.get(machine, "name")
    }

    relocation
    |> RelocationStatus.describe()
    |> Map.drop([:id])
    |> Map.merge(identity)
  end

  @typep execution :: %{
           result: term(),
           vm_id: String.t() | nil,
           operation_id: String.t() | nil,
           clone_request_id: String.t() | nil,
           relocation_id: String.t() | nil,
           relocation_retry_id: String.t() | nil,
           resize_request_id: String.t() | nil,
           wake_request_id: String.t() | nil,
           physical?: boolean()
         }

  @spec execution(tuple() | map()) :: execution()
  defp execution({result, vm_id, operation_id}),
    do: execution(%{result: result, vm_id: vm_id, operation_id: operation_id})

  defp execution({result, vm_id, operation_id, clone_request_id}),
    do:
      execution(%{
        result: result,
        vm_id: vm_id,
        operation_id: operation_id,
        clone_request_id: clone_request_id
      })

  defp execution(%{result: _} = values) do
    defaults = %{
      vm_id: nil,
      operation_id: nil,
      clone_request_id: nil,
      relocation_id: nil,
      relocation_retry_id: nil,
      resize_request_id: nil,
      wake_request_id: nil
    }

    values = Map.merge(defaults, values)

    Map.put(
      values,
      :physical?,
      Enum.any?(
        [
          values.operation_id,
          values.clone_request_id,
          values.relocation_id,
          values.relocation_retry_id,
          values.resize_request_id,
          values.wake_request_id
        ],
        &(&1 != nil)
      )
    )
  end

  defp deletion_complete?(%{kind: :delete, vm_id: id}),
    do:
      Ledger.history!(VirtualMachine, id: id)
      |> hd()
      |> Map.fetch!(:archived_at)
      |> is_nil()
      |> Kernel.not()

  defp deletion_complete?(_), do: true

  defp finish(request, status, extra),
    do:
      Ledger.update!(request, :finish, %{
        status: status,
        result: Map.merge(request.result, json(extra))
      })

  defp envelope(request),
    do: %{
      version: 1,
      request_id: request.request_id,
      status: Atom.to_string(request.status),
      operation_id:
        request.operation_id || request.clone_request_id || request.resize_request_id ||
          request.relocation_retry_id || request.relocation_id || request.wake_request_id,
      result: request.result
    }
end
