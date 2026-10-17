defmodule Marshall.EditorFixture do
  @moduledoc "Synthetic execution evidence driving real editor domain authority."
  alias Marshall.Accounts.{Login, Security, User}
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Credentials,
    Host,
    HostReports,
    Images,
    Ledger,
    Operation,
    ProvisionerControl
  }

  alias Marshall.ComputeFixtures
  alias Marshall.TerminalFixtures

  @type t :: %{
          owner: User.t(),
          token: String.t(),
          vm: map(),
          service: map(),
          service_token: String.t(),
          host: map(),
          report: map(),
          connection: map(),
          descriptor: map()
        }

  @spec descriptor() :: %{String.t() => String.t() | pos_integer()}
  def descriptor,
    do: %{
      "protocol" => 1,
      "commit" => String.duplicate("a", 40),
      "release" => String.duplicate("b", 64)
    }

  # @cc [owner:ghuntley,label:verification] editor-fixture-real-domain-boundary
  # Fixture images MUST be registered with a validated content-bound descriptor,
  # never mutate an existing immutable image. Provisioning, execution outcomes,
  # gateway authentication and browser login MUST use their production actions.
  # Synthetic execution evidence MUST NOT be claimed as native guest isolation.
  @spec new(atom()) :: t()
  def new(profile \\ :standard) do
    manifest =
      ComputeFixtures.image_manifest()
      |> Map.put("version", 4)
      |> Map.put("editor", descriptor())

    {:ok, image} = Images.register(manifest, "editor-test-image")
    machine = "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    source = ComputeFixtures.host_fixture(%{machine_id: machine})

    report = %{
      source.report
      | sequence: 2,
        sampled_at: Ledger.now(),
        inventory:
          source.report.inventory
          |> Map.put("images", [ComputeFixtures.image_id(), image.id])
          |> Map.put("terminal_protocol", 2)
    }

    {:ok, :ok} = HostReports.ingest(source.host.id, source.epoch, report)
    owner = ComputeFixtures.user()
    others = Ledger.read!(Host) |> Enum.filter(&(&1.id != source.host.id and &1.enabled))
    Enum.each(others, &Ledger.update!(&1, :configure, %{enabled: false}))

    vm =
      try do
        {:ok, vm} =
          Marshall.Compute.provision(
            ComputeFixtures.request(%{image_id: image.id, profile: profile}),
            actor: owner
          )

        vm
      after
        Enum.each(others, &Ledger.update!(&1, :configure, %{enabled: true}))
      end

    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    {:ok, credential} = Credentials.rotate(vm.host_id, 3600)
    connection = TerminalFixtures.connect(credential.token, machine)

    {:ok, _} =
      ProvisionerControl.exchange_execution(
        credential.token,
        Map.merge(connection, %{
          report: report,
          acknowledgements: [],
          outcomes: [
            %{
              id: Ash.UUID.generate(),
              vm_id: vm.id,
              placement_id: operation.placement_id,
              execution_epoch: operation.execution_epoch,
              operation_id: operation.id,
              generation: vm.generation,
              sequence: 1,
              state: :running,
              compute_empty: false,
              disk_present: true,
              cleanup_complete: false,
              reason: :none
            }
          ]
        })
      )

    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: vm.id)
    token = TerminalFixtures.user_token(owner)
    {:ok, jti, _} = Login.verify(token, owner)
    owner = Security.bind(owner, jti)
    {service_token, _} = Marshall.Ingress.Token.issue()

    {:ok, service} =
      Marshall.Ingress.configure_service(
        %{
          name: "editor-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: source.host.id,
          token: service_token,
          addresses: ["192.0.2.9"]
        },
        actor: SystemActor.compute()
      )

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    {:ok, _} =
      Marshall.Ingress.publish_host_key(%{token: service_token, public_key: key},
        actor: SystemActor.compute()
      )

    %{
      owner: owner,
      token: token,
      vm: vm,
      service: service,
      service_token: service_token,
      host: source.host,
      report: report,
      connection: connection,
      descriptor: descriptor()
    }
  end

  @spec fresh(t()) :: :ok
  def fresh(c) do
    [host] = Ledger.read!(Host, id: c.host.id)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    :ok
  end

  @spec label(t(), User.t()) :: String.t()
  def label(c, user) do
    {:ok, account} =
      Ledger.transaction(fn -> Marshall.Accounts.GuestAccounts.ensure!(user.id) end)

    OverallsProtocol.EditorName.label(c.vm.id, account.id)
  end

  @spec begin_login(t(), String.t()) :: {map(), String.t()}
  def begin_login(c, label) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = :crypto.hash(:sha256, state) |> Base.encode16(case: :lower)

    {:ok, login} =
      Marshall.Editor.begin_editor_login(
        %{service_token: c.service_token, label: label, state_digest: digest},
        actor: SystemActor.compute()
      )

    {login, state}
  end

  @spec cookie(t(), User.t()) :: map()
  def cookie(c, user) do
    label = label(c, user)
    {login, state} = begin_login(c, label)
    token = if user.id == c.owner.id, do: c.token, else: TerminalFixtures.user_token(user)
    {:ok, jti, _} = Login.verify(token, user)
    actor = Security.bind(user, jti)

    {:ok, approved} =
      Marshall.Editor.authorize_editor_login(%{ticket: login.ticket, login_token: token},
        actor: actor
      )

    {:ok, result} =
      Marshall.Editor.exchange_editor_login(
        %{
          service_token: c.service_token,
          ticket: login.ticket,
          code: approved.code,
          state: state
        },
        actor: SystemActor.compute()
      )

    Map.merge(result, %{label: label, token: token})
  end

  @spec open(t(), map()) :: {:ok, map()} | {:error, term()}
  def open(c, cookie),
    do:
      Marshall.Editor.open_editor(
        %{service_token: c.service_token, label: cookie.label, cookie: cookie.cookie},
        actor: SystemActor.compute()
      )

  @spec renew(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def renew(c, ticket),
    do:
      Marshall.Editor.renew_editor(%{service_token: c.service_token, stream_token: ticket},
        actor: SystemActor.compute()
      )
end
