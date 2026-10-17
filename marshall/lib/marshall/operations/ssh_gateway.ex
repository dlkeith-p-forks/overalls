defmodule Marshall.Operations.SSHGateway do
  @moduledoc "Trusted operator gateway workflow; credentials remain in private files."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Operations.{PrivateFiles, Privacy}
  alias Marshall.SSH
  alias Marshall.SSH.Token

  # @cc [owner:ghuntley,label:security;recovery] gateway-token-before-authority
  # Preparation MUST exclusively create and sync a private token file without
  # changing gateway authority. It MUST NOT return the token or overwrite a file.
  # The same prepared file can then be reapplied after an uncertain database reply.
  @spec prepare(Path.t()) :: {:ok, map()} | {:error, atom()}
  def prepare(path) do
    Privacy.run(fn ->
      PrivateFiles.with_new(path, fn file ->
        {token, _hash} = Token.issue(:gateway)

        case PrivateFiles.write_sync(file, path, token) do
          :ok -> {:ok, %{prepared: true}}
          error -> error
        end
      end)
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] gateway-operator-ash-authority
  # Applying MUST read a bounded private file and use the Ash gateway action with
  # the trusted system actor. Reapplying an active token MUST preserve generation;
  # rotation MUST invalidate prior sessions through existing domain authority.
  # Returns MUST contain only public gateway metadata or fixed errors.
  @spec configure(String.t(), Path.t()) :: {:ok, map()} | {:error, atom()}
  def configure(name, path) do
    apply_file(:configure_gateway, name, path)
  end

  # @cc [owner:ghuntley,label:security;recovery] gateway-operator-idempotent-bootstrap
  # Bootstrap MUST use the current private file and Ash ensure action, preserving
  # generation on retry and refusing revoked/mismatched authority. It MUST NOT
  # fall back to the operator rotation action or disclose credential contents.
  @spec ensure(String.t(), Path.t()) :: {:ok, map()} | {:error, atom()}
  def ensure(name, path), do: apply_file(:ensure_gateway, name, path)

  defp apply_file(action, name, path) do
    Privacy.run(fn ->
      with {:ok, token} <- PrivateFiles.read(path),
           {:ok, _hash} <- Token.digest(token, :gateway) do
        apply(SSH, action, [%{name: name, token: token}, [actor: SystemActor.compute()]])
        |> public_result()
      else
        _ -> {:error, :invalid_gateway_file}
      end
    end)
  end

  @spec disable(String.t()) :: {:ok, map()} | {:error, atom()}
  def disable(id) do
    Privacy.run(fn ->
      SSH.disable_gateway(%{id: id}, actor: SystemActor.compute()) |> public_result()
    end)
  end

  defp public_result({:ok, metadata}),
    do: {:ok, Map.take(metadata, [:id, :name, :generation, :enabled])}

  defp public_result(_), do: {:error, :gateway_operation_failed}
end
