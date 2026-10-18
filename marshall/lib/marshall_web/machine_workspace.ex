defmodule MarshallWeb.MachineWorkspace do
  @moduledoc "Shared, actor-authorized machine header state and power actions."
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3, push_navigate: 2]
  alias Marshall.Accounts.{Security, User}
  alias Marshall.{Access, Compute}

  @type socket :: Phoenix.LiveView.Socket.t()
  @type connection ::
          %{
            install: String.t(),
            install_windows: String.t(),
            ssh: String.t()
          }
          | nil

  @spec on_mount(:default, map(), map(), socket()) :: {:cont, socket()}
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(
       machine_connection: nil,
       machine_power_key: Ash.UUID.generate(),
       admin_access_expired: false
     )
     |> attach_hook(:machine_power, :handle_event, &power_event/3)}
  end

  # @cc [owner:ghuntley,label:security] machine-header-current-authority
  # Header actions MUST use the current actor and domain admission. Connection
  # commands MUST use an authorized SSH endpoint and configured origins only;
  # failed or revoked reads MUST clear previously displayed commands.
  @spec put_vm(socket(), map()) :: socket()
  def put_vm(socket, vm) do
    vm =
      Map.update!(vm, :permissions, &Map.merge(%{read: false, write: false, manage: false}, &1))

    assign(socket,
      vm: vm,
      machine_connection: connection(vm, socket.assigns.current_user),
      admin_access_expired: false
    )
  end

  # @cc [owner:ghuntley,label:security;product] machine-admin-recovery-not-authority
  # Expired administrator overrides MUST offer the Fleet workloads recovery
  # path. Recovery hints MUST NOT replace domain authorization, affect normal
  # owner/sharing permissions, or suggest elevation grants foreign Customer access.
  @spec administrative_access_expired?(socket(), :read | :write | :manage) :: boolean()
  def administrative_access_expired?(socket, permission) do
    actor = socket.assigns.current_user

    if match?(%User{administrator: true, deleted_at: nil}, Security.current(actor.id)) and
         not Security.recent?(actor) do
      case socket.assigns[:vm] do
        %{owner: false, profile: profile, id: id} when profile != :customer ->
          case Compute.get_vm(%{vm_id: id}, actor: %User{id: actor.id}) do
            {:ok, vm} ->
              not Map.fetch!(vm.permissions, permission)

            {:error, %Marshall.Compute.Error{reason: :forbidden}} ->
              true

            {:error, %Ash.Error.Invalid{errors: [%Marshall.Compute.Error{reason: :forbidden}]}} ->
              true

            _ ->
              false
          end

        nil ->
          socket.assigns[:admin_access_expired] == true

        _ ->
          false
      end
    else
      false
    end
  end

  @spec return_after_access_loss(socket(), :read | :write | :manage) :: socket()
  def return_after_access_loss(socket, permission) do
    if administrative_access_expired?(socket, permission) do
      socket
      |> assign(machine_connection: nil)
      |> put_flash(
        :error,
        "Administrative verification expired. Choose the machine in Fleet workloads and verify your passkey to reopen it."
      )
      |> push_navigate(to: "/admin/workloads")
    else
      socket
      |> assign(machine_connection: nil)
      |> put_flash(:error, "This machine is unavailable or your access has ended.")
      |> push_navigate(to: "/machines")
    end
  end

  @spec connection(map(), Marshall.Accounts.User.t()) :: connection()
  defp connection(vm, actor) do
    zone = Application.get_env(:marshall, :ingress_zone)

    if vm.permissions.write && vm.profile != :inception && is_binary(zone) do
      case Marshall.Ingress.get_ssh_endpoint(%{vm_id: vm.id}, actor: actor) do
        {:ok, endpoint} ->
          host = endpoint.label <> "." <> zone
          origin = MarshallWeb.Endpoint.url()

          # @cc [owner:ghuntley,label:product] workstation-single-ssh-command
          # One `ssh HOST` command reconnects on every platform: install.ps1
          # makes its verified OpenSSH 9.6+ client the default `ssh` on Windows.
          %{
            install: "curl -fsSL #{origin}/bin/install.sh | bash -s -- #{origin} #{zone} #{host}",
            install_windows: windows_install(origin, zone, host),
            ssh: "ssh #{host}"
          }

        _ ->
          nil
      end
    end
  end

  # @cc [owner:ghuntley,label:security] windows-install-command
  # The Windows command MUST run only the deployment's /bin/install.ps1 with the
  # same validated origin, zone and host as the shell command, each as one
  # single-quoted PowerShell argument; the values are DNS names and an https
  # origin, so they contain no quote to escape.
  @spec windows_install(String.t(), String.t(), String.t()) :: String.t()
  defp windows_install(origin, zone, host) do
    script =
      "& ([scriptblock]::Create((Invoke-RestMethod '#{origin}/bin/install.ps1'))) " <>
        "'#{origin}' '#{zone}' '#{host}'"

    "powershell -NoProfile -ExecutionPolicy Bypass -Command \"#{script}\""
  end

  # @cc [owner:ghuntley,label:security;product] machine-pin-current-actor
  # Pin toggles MUST send the server-selected VM id and the current actor to the
  # Access domain; the displayed state only chooses pin or unpin, and a stale
  # choice is absorbed by the coordinator's idempotent result. Refusals MUST
  # map to the fixed public messages below, never to coordinator detail.
  @spec toggle_pin(socket(), String.t(), boolean()) :: socket()
  def toggle_pin(socket, vm_id, pinned?) do
    actor = socket.assigns.current_user

    result =
      if pinned?,
        do: Access.unpin_machine(%{vm_id: vm_id}, actor: actor),
        else: Access.pin_machine(%{vm_id: vm_id}, actor: actor)

    case result do
      {:ok, _pin} -> socket
      {:error, error} -> put_flash(socket, :error, pin_message(error))
    end
  end

  @spec pin_message(Exception.t()) :: String.t()
  defp pin_message(error) do
    text = Exception.message(error)

    cond do
      String.contains?(text, "pin_limit") ->
        "You can pin up to #{Access.Pins.limit()} machines. Unpin one before pinning another."

      String.contains?(text, "vm_deleted") ->
        "This machine is being deleted and cannot be pinned."

      String.contains?(text, "machine_failed") ->
        "A failed machine cannot be pinned."

      true ->
        "The pin could not be changed. Refresh and try again."
    end
  end

  @spec power_event(String.t(), map(), socket()) :: {:halt | :cont, socket()}
  defp power_event(
         "pin",
         %{"id" => id, "pinned" => pinned},
         %{assigns: %{vm: %{id: id}}} = socket
       )
       when is_binary(id) and is_binary(pinned) do
    socket = toggle_pin(socket, id, pinned == "true")

    case Compute.get_vm(%{vm_id: id}, actor: socket.assigns.current_user) do
      {:ok, current} -> {:halt, put_vm(socket, current)}
      _ -> {:halt, socket}
    end
  end

  defp power_event(
         "machine-power",
         %{"kind" => kind, "key" => key},
         %{assigns: %{vm: %{id: _}}} = socket
       )
       when kind in ["start", "stop"] do
    case Compute.lifecycle(%{vm_id: socket.assigns.vm.id, kind: kind, idempotency_key: key},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        socket = assign(socket, machine_power_key: Ash.UUID.generate())

        case Compute.get_vm(%{vm_id: socket.assigns.vm.id}, actor: socket.assigns.current_user) do
          {:ok, current} -> {:halt, put_vm(socket, current)}
          _ -> {:halt, assign(socket, machine_connection: nil)}
        end

      _ ->
        if administrative_access_expired?(socket, :manage) do
          {:halt, return_after_access_loss(socket, :manage)}
        else
          {:halt,
           socket
           |> assign(machine_connection: nil)
           |> put_flash(:error, "The machine could not be updated. Refresh and try again.")}
        end
    end
  end

  defp power_event(_event, _params, socket), do: {:cont, socket}
end
