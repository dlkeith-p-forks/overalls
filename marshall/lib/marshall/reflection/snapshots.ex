defmodule Marshall.Reflection.Snapshots do
  @moduledoc "Secret-free, current-execution guest reflection projections."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Image, Ledger, Operation, VirtualMachine}
  alias Marshall.Galileo.{Attachment, Integration, IntegrationHeader, Ownership}
  require Ash.Query

  @spec fetch(map()) :: {:ok, map()} | {:error, :unavailable}
  def fetch(binding) when is_map(binding) do
    with {:ok, vm} <- current_vm(binding),
         {:ok, host} <- current_host(binding),
         {:ok, image} <- image(vm.image_id),
         {:ok, owner} <- owner(vm.owner_id),
         {:ok, team} <- team(vm.team_id),
         {:ok, integrations} <- integrations(vm) do
      {:ok,
       %{
         "version" => 1,
         "guest" => %{
           "id" => vm.id,
           "name" => vm.name,
           "profile" => Atom.to_string(vm.profile),
           "architecture" => Atom.to_string(vm.architecture),
           "operating_system" => operating_system(image),
           "vcpu" => vm.vcpu,
           "memory_bytes" => vm.memory_bytes,
           "disk_bytes" => vm.disk_bytes,
           "image_id" => vm.image_id,
           "generation" => vm.generation,
           "state" => "running",
           "owner_email" => owner.email,
           "team_name" => team && team.name,
           "node" => %{"id" => host.id, "name" => host.name},
           "labels" => vm.labels,
           "comment" => vm.comment
         },
         "integrations" => integrations
       }}
    else
      _ -> {:error, :unavailable}
    end
  end

  def fetch(_), do: {:error, :unavailable}

  defp current_vm(binding) do
    with {:ok, vm} <- one(VirtualMachine, id: binding["vm_id"]),
         true <- vm.current_placement_id == binding["placement_id"],
         true <- vm.execution_epoch == binding["execution_epoch"],
         true <- vm.desired_state == :running and vm.observed_state == :running,
         true <- OverallsProtocol.ProfilePolicy.allows?(vm.profile, :private_services),
         true <- live_start?(vm) do
      {:ok, vm}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp current_host(binding) do
    with {:ok, host} <- one(Host, id: binding["host_id"]),
         true <- host.enabled and host.maintenance_mode != :retired,
         true <- host.id == binding["host_id"] do
      {:ok, host}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp live_start?(vm) do
    Operation
    |> Ash.Query.filter(
      vm_id == ^vm.id and placement_id == ^vm.current_placement_id and
        execution_epoch == ^vm.execution_epoch and generation == ^vm.generation and
        status == :completed and kind in [:start, :provision, :resume]
    )
    |> Ash.exists?(actor: SystemActor.compute())
  end

  defp image(id), do: one(Image, id: id)
  defp owner(id), do: one(Marshall.Accounts.User, id: id)
  defp team(nil), do: {:ok, nil}
  defp team(id), do: one(Marshall.Teams.Team, id: id)

  defp one(resource, filters) do
    case Ledger.read!(resource, filters) do
      [value] -> {:ok, value}
      _ -> {:error, :unavailable}
    end
  end

  defp integrations(vm) do
    named =
      Integration
      |> Ash.Query.filter(archived_at == nil)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.filter(&Ownership.live?/1)
      |> Enum.filter(&eligible?(&1, vm))
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&named_integration/1)

    {:ok, [builtin("reflection"), builtin("llm")] ++ named}
  rescue
    _ -> {:error, :unavailable}
  end

  defp eligible?(integration, vm) do
    attached =
      Attachment
      |> Ash.Query.filter(
        integration_id == ^integration.id and vm_id == ^vm.id and archived_at == nil
      )
      |> Ash.exists?(actor: SystemActor.compute())

    attached or (is_binary(integration.team_id) and integration.team_id == vm.team_id)
  end

  defp builtin("reflection"),
    do:
      integration(
        "reflection",
        "reflection",
        "https://reflection.internal",
        "curl --fail --silent https://reflection.internal/"
      )

  defp builtin("llm"),
    do:
      integration(
        "llm",
        "llm",
        "https://llm.internal",
        "curl --fail --silent https://llm.internal/v1/models"
      )

  defp named_integration(integration) do
    type = if integration.peer, do: "vm", else: "http"
    url = "https://" <> integration.name <> ".integration.internal"

    headers =
      IntegrationHeader
      |> Ash.Query.filter(integration_id == ^integration.id and archived_at == nil)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(&%{"name" => &1.name, "kind" => Atom.to_string(&1.kind)})
      |> Enum.sort_by(&{&1["name"], &1["kind"]})

    integration(integration.name, type, url, "curl --fail --silent " <> url <> "/")
    |> Map.put("comment", integration.comment)
    |> Map.put("headers", headers)
  end

  defp integration(name, type, url, help) do
    %{
      "name" => name,
      "type" => type,
      "comment" => "",
      "url" => url,
      "paths" => [%{"path" => "/", "description" => "Service endpoint"}],
      "help" => help,
      "headers" => []
    }
  end

  defp operating_system(%{manifest: manifest}) do
    case OverallsProtocol.ImageManifest.validate(manifest) do
      {:ok, %{guest_agents: :linux}} -> "linux"
      {:ok, %{guest_agents: :windows_v1}} -> "windows"
      {:ok, %{guest_agents: :freebsd_v1}} -> "freebsd"
      {:ok, %{guest_agents: :illumos_v1}} -> "illumos"
      _ -> "unknown"
    end
  end

  defp operating_system(_), do: "unknown"
end
