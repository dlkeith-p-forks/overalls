defmodule Marshall.SSH.HostCertificates do
  @moduledoc "Central, transactional SSH host issuance. Secrets never leave the signer."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Compute.Ledger
  alias Marshall.SSH.HostCertificate
  alias OverallsProtocol.{SSHHostCertificate, SSHTrust}
  require Ash.Query

  @impl true
  def run(input, _, %{actor: %Marshall.Authorization.SystemActor{purpose: :compute}}) do
    case Ledger.transaction(fn -> issue!(input.arguments) end, :system) do
      {:ok, %{error: "unavailable"}} -> {:error, :unavailable}
      result -> result
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def run(_, _, _), do: {:error, :unauthorized}

  @spec policy() :: {:ok, SSHTrust.t()} | {:error, :invalid_trust}
  def policy do
    Application.get_env(:marshall, :ssh_host_trust) |> SSHTrust.parse()
  end

  # @cc [owner:ghuntley,label:security;concurrency] ssh-certificate-authority-commit
  # Issuance MUST retain authenticated service/VM locks through signing and
  # publication, derive its principal from server authority, and serialize one
  # subject's generations. A retry MUST reuse its matching issued certificate
  # outside the renewal window. Matching failures MUST retry the same generation
  # rather than append unbounded history during signer outages.
  # No response may publish an uncommitted generation or expose signing material.
  defp issue!(request) do
    {:ok, policy} = policy()

    {:ok, %{algorithm: "ssh-ed25519", public_key: key}} =
      OverallsProtocol.SSHKey.parse(request.public_key)

    {subject, principal} = authority!(request, key, policy)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["ssh-certificate:" <> subject],
      log: false
    )

    now = DateTime.utc_now() |> DateTime.to_unix()
    if policy.retirement <= now + SSHTrust.renewal_window(), do: Ledger.rollback(:unavailable)

    current =
      HostCertificate
      |> Ash.Query.filter(subject == ^subject and status != :superseded)
      |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

    matching =
      Enum.find(
        current,
        &(&1.status == :issued and &1.public_key == key and &1.ca == policy.ca and
            &1.principal == principal and &1.valid_before > now + SSHTrust.renewal_window())
      )

    if matching do
      reply(matching)
    else
      retryable =
        Enum.find(current, fn record ->
          record.status == :failed and record.public_key == key and record.ca == policy.ca and
            record.principal == principal and
            record.valid_before > now + SSHTrust.renewal_window()
        end)

      record =
        if retryable do
          Ledger.update!(retryable, :retry, %{})
        else
          Enum.each(current, &Ledger.update!(&1, :supersede, %{}))
          <<serial::unsigned-64>> = :crypto.strong_rand_bytes(8)

          Ledger.create!(HostCertificate, :record, %{
            subject: subject,
            principal: principal,
            public_key: key,
            ca: policy.ca,
            serial: Bitwise.band(serial, 0x7FFFFFFFFFFFFFFF),
            valid_after: max(0, now - 300),
            valid_before: min(now + SSHTrust.lifetime(), policy.retirement)
          })
        end

      case sign(record) do
        {:ok, line} ->
          record |> Ledger.update!(:issue, %{certificate: line}) |> reply()

        _ ->
          Ledger.update!(record, :fail, %{})
          %{version: 1, error: "unavailable"}
      end
    end
  end

  defp authority!(%{role: :porsche, token: token}, _key, policy) do
    gateway = Marshall.SSH.Authority.authenticate_gateway!(token)
    {"porsche:" <> gateway.id, policy.management_host}
  end

  defp authority!(%{role: :audi, token: token}, key, policy) do
    service = Marshall.Ingress.Services.authenticate!(token)

    unless service.role == :gateway and service.ssh_host_key == key,
      do: Ledger.rollback(:unauthorized)

    {:ok, principal} = SSHHostCertificate.gateway_principal(key, policy.management_host)
    {"audi:" <> service.id, principal}
  end

  defp authority!(%{role: :guest, token: token, binding: wire}, _key, policy) do
    {:ok, binding} = OverallsProtocol.PrivateServices.roster_binding(wire)
    authority = Marshall.Inference.Credentials.authenticate_locked!(token)
    unless authority.host_id == binding.host_id, do: Ledger.rollback(:unauthorized)

    vm =
      Ledger.lock!(Marshall.Compute.VirtualMachine, binding.vm_id) ||
        Ledger.rollback(:unauthorized)

    Marshall.SSH.GuestAccess.bootstrap_execution!(vm, binding)
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: vm.id)
    {"guest:" <> vm.id, endpoint.label <> "." <> policy.zone}
  end

  defp sign(record) do
    with path when is_binary(path) <- Application.get_env(:marshall, :ssh_host_ca_key_file),
         {:ok, %{type: :regular, size: size}} when size <= 16_384 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         [{{:ECPrivateKey, 1, seed, {:namedCurve, {1, 3, 101, 112}}, _, _}, _} | _] <-
           :ssh_file.decode(bytes, :openssh_key_v1) do
      SSHHostCertificate.issue(
        record.public_key,
        record.ca,
        seed,
        [record.principal],
        record.serial,
        record.id,
        record.valid_after,
        record.valid_before
      )
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp reply(record),
    do: %{version: 1, certificate: record.certificate, principal: record.principal, ca: record.ca}
end
