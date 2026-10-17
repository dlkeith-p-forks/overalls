defmodule OverallsAntithesis.Integrations do
  @moduledoc "Closed Galileo fixture mutations through the production Ash domain."

  import Bitwise, only: [&&&: 2]

  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Galileo

  @origin_a "https://integration-a.fixture.test"
  @origin_b "https://integration-b.fixture.test"
  @auth_file "/run/overalls-origin-shared/integration-auth-token"
  @auth_next_file "/run/overalls-origin-shared/integration-auth-next-token"
  @static_file "/run/overalls-origin-shared/integration-static-value"
  @generation_file "/run/overalls-control-secrets/integration-generation.json"
  @operations ~w(integration.create integration.retarget integration.rotate integration.attach integration.detach)

  @type request :: %{String.t() => String.t() | integer()}
  @type receipt :: %{String.t() => String.t() | integer() | boolean() | map()}

  # @cc [owner:ghuntley,label:security;verification] fixture-galileo-closed-actions
  # Requests MUST select only these fixed fixture operations. The actor, name,
  # HTTPS origins, strip prefix and injected header names MUST come from this
  # module, never from request data. Each mutation MUST use Galileo's Ash action.
  @spec main([String.t()]) :: :ok | no_return()
  def main([operation, manifest_path, request_path, result_path]) when operation in @operations do
    if System.get_env("MARSHALL_INSTANCE_ID") != "enrollment-operator" or
         Application.get_env(:marshall, :operator_mode) != true or
         not File.regular?("/run/overalls-oracle/fixture.json") do
      System.halt(1)
    end

    manifest = OverallsAntithesis.Fixture.read_manifest!(manifest_path)
    {:ok, request} = request_path |> File.read!() |> JSON.decode!() |> validate_request(operation)
    actor = OverallsAntithesis.Fixture.actor!(manifest, "admin_a")

    result = execute(operation, manifest, request, actor)

    receipt =
      case result do
        {:ok, value} ->
          %{
            "version" => 1,
            "request_id" => request["request_id"],
            "operation" => operation,
            "status" => "ok",
            "value" => value
          }

        {:error, reason} ->
          %{
            "version" => 1,
            "request_id" => request["request_id"],
            "operation" => operation,
            "status" => "error",
            "reason" => closed_reason(reason)
          }
      end

    write_private!(result_path, receipt)
  rescue
    _ -> System.halt(1)
  catch
    _, _ -> System.halt(1)
  end

  def main(_), do: System.halt(1)

  @doc "Validate the operator's fixed, versioned request shape without creating atoms."
  @spec validate_request(term(), String.t()) :: {:ok, request()} | {:error, :invalid_request}
  def validate_request(request, operation) when is_map(request) and operation in @operations do
    keys =
      if operation in ["integration.attach", "integration.detach"],
        do: ~w(operation request_id version vm_id),
        else: ~w(operation request_id version)

    valid =
      Enum.sort(Map.keys(request)) == keys and
        request["version"] === 1 and request["operation"] == operation and
        OverallsProtocol.uuid?(request["request_id"]) and
        (not Map.has_key?(request, "vm_id") or OverallsProtocol.uuid?(request["vm_id"]))

    if valid, do: {:ok, request}, else: {:error, :invalid_request}
  end

  def validate_request(_, _), do: {:error, :invalid_request}

  @spec execute(String.t(), map(), request(), Marshall.Accounts.User.t()) ::
          {:ok, map()} | {:error, term()}
  defp execute("integration.create", manifest, request, actor) do
    with {:ok, value} <- configure(manifest, request, actor, @origin_a, 1) do
      write_generation!(manifest, 1)
      {:ok, value}
    end
  end

  defp execute("integration.retarget", manifest, request, actor) do
    with {:ok, current} <- Galileo.show_integration(%{name: name(manifest)}, actor: actor),
         {:ok, _target} <- approved_target(current.target),
         {:ok, generation} <- read_generation(manifest) do
      configure(manifest, request, actor, @origin_b, generation)
    end
  end

  # @cc [owner:ghuntley,label:security] fixture-galileo-rotate-secret
  # A rotated bearer MUST come only from the origin's private runtime token
  # file and enter Galileo through its authorized configuration action. Neither
  # the receipt nor diagnostics may contain the token or stored header value.
  defp execute("integration.rotate", manifest, request, actor) do
    with {:ok, current} <- Galileo.show_integration(%{name: name(manifest)}, actor: actor),
         {:ok, target} <- approved_target(current.target),
         {:ok, _generation} <- read_generation(manifest),
         {:ok, value} <- configure(manifest, request, actor, target, 2) do
      write_generation!(manifest, 2)
      {:ok, value}
    end
  end

  defp execute("integration.attach", manifest, request, actor) do
    change_attachment(:attach, manifest, request, actor)
  end

  defp execute("integration.detach", manifest, request, actor) do
    change_attachment(:detach, manifest, request, actor)
  end

  @spec configure(map(), request(), Marshall.Accounts.User.t(), String.t(), 1 | 2) ::
          {:ok, map()} | {:error, term()}
  defp configure(manifest, request, actor, target, generation) do
    with {:ok, bearer} <- bearer(generation),
         {:ok, static} <- private_value(@static_file),
         {:ok, integration} <-
           Galileo.configure_integration(
             %{
               name: name(manifest),
               target: target,
               strip_prefix: "/fixture",
               peer: false,
               headers: [
                 %{kind: :bearer, name: "Authorization", value: bearer},
                 %{kind: :static, name: "X-Fixture-Static", value: static}
               ],
               idempotency_key: request["request_id"]
             },
             actor: actor
           ),
         {:ok, shown} <- Galileo.show_integration(%{name: name(manifest)}, actor: actor),
         true <- shown.id == integration.id and shown.target == target do
      {:ok, base_value(integration.id, name(manifest), target)}
    else
      false -> {:error, :verification_failed}
      other -> other
    end
  end

  @spec change_attachment(:attach | :detach, map(), request(), Marshall.Accounts.User.t()) ::
          {:ok, map()} | {:error, term()}
  defp change_attachment(action, manifest, request, actor) do
    vm_id = request["vm_id"]

    with :ok <- owned_vm(vm_id, actor),
         {:ok, integration} <- Galileo.show_integration(%{name: name(manifest)}, actor: actor),
         {:ok, target} <- approved_target(integration.target),
         {:ok, result} <- attachment_action(action, name(manifest), vm_id, actor),
         true <- result.integration_id == integration.id and result.vm_id == vm_id do
      {:ok,
       base_value(integration.id, name(manifest), target)
       |> Map.put("vm_id", vm_id)
       |> Map.put("attached", action == :attach)}
    else
      false -> {:error, :verification_failed}
      other -> other
    end
  end

  @spec owned_vm(String.t(), Marshall.Accounts.User.t()) :: :ok | {:error, term()}
  defp owned_vm(vm_id, actor) do
    with {:ok, %{id: ^vm_id}} <- Marshall.Compute.get_vm(%{vm_id: vm_id}, actor: actor),
         [%VirtualMachine{owner_id: owner_id}] <- Ledger.read!(VirtualMachine, id: vm_id),
         true <- owner_id == actor.id do
      :ok
    else
      false -> {:error, :wrong_fixture_owner}
      [] -> {:error, :unknown_machine}
      other -> other
    end
  end

  @spec attachment_action(:attach | :detach, String.t(), String.t(), Marshall.Accounts.User.t()) ::
          {:ok, map()} | {:error, term()}
  defp attachment_action(:attach, name, vm_id, actor),
    do: Galileo.attach_integration(%{name: name, vm_id: vm_id}, actor: actor)

  defp attachment_action(:detach, name, vm_id, actor),
    do: Galileo.detach_integration(%{name: name, vm_id: vm_id}, actor: actor)

  @spec bearer(1 | 2) :: {:ok, String.t()} | {:error, term()}
  defp bearer(1), do: private_value(@auth_file)
  defp bearer(2), do: private_value(@auth_next_file)

  @spec read_generation(map()) :: {:ok, 1 | 2} | {:error, :invalid_generation_state}
  defp read_generation(manifest) do
    with {:ok, raw} <- File.read(@generation_file),
         {:ok, %{"fixture_id" => id, "generation" => generation}} <- JSON.decode(raw),
         true <- id == manifest["fixture_id"] and generation in [1, 2] do
      {:ok, generation}
    else
      _ -> {:error, :invalid_generation_state}
    end
  end

  @spec write_generation!(map(), 1 | 2) :: :ok
  defp write_generation!(manifest, generation) do
    temporary = @generation_file <> ".new"

    :ok =
      File.write(
        temporary,
        JSON.encode!(%{"fixture_id" => manifest["fixture_id"], "generation" => generation})
      )

    :ok = File.chmod(temporary, 0o600)
    :ok = File.rename(temporary, @generation_file)
  end

  @spec private_value(String.t()) :: {:ok, String.t()} | {:error, :invalid_fixture_secret}
  defp private_value(path) do
    with {:ok, stat} <- File.stat(path),
         true <-
           stat.type == :regular and (stat.mode &&& 0o077) == 0 and stat.size in 1..4096,
         {:ok, raw} <- File.read(path),
         value = String.trim_trailing(raw, "\n"),
         true <-
           byte_size(value) in 1..4096 and String.valid?(value) and
             not String.contains?(value, ["\r", "\n", "\0"]) do
      {:ok, value}
    else
      _ -> {:error, :invalid_fixture_secret}
    end
  end

  @spec approved_target(term()) :: {:ok, String.t()} | {:error, :unapproved_target}
  defp approved_target(target) when target in [@origin_a, @origin_b], do: {:ok, target}
  defp approved_target(_), do: {:error, :unapproved_target}

  @spec name(map()) :: String.t()
  defp name(%{"fixture_id" => fixture_id}), do: "at-" <> binary_part(fixture_id, 0, 20)

  @spec base_value(String.t(), String.t(), String.t()) :: map()
  defp base_value(id, name, target) do
    %{
      "integration_id" => id,
      "name" => name,
      "target" => if(target == @origin_a, do: "A", else: "B")
    }
  end

  @spec closed_reason(term()) :: String.t()
  defp closed_reason(%Marshall.Compute.Error{reason: reason}) when is_atom(reason),
    do: Atom.to_string(reason)

  defp closed_reason(reason)
       when reason in [
              :invalid_fixture_secret,
              :invalid_generation_state,
              :unapproved_target,
              :verification_failed,
              :wrong_fixture_owner,
              :unknown_machine
            ],
       do: Atom.to_string(reason)

  defp closed_reason(_), do: "action_refused"

  @spec write_private!(String.t(), receipt()) :: :ok
  defp write_private!(path, receipt) do
    temporary = path <> ".new"
    :ok = File.write(temporary, JSON.encode!(receipt))
    :ok = File.chmod(temporary, 0o600)
    :ok = File.rename(temporary, path)
  end
end
