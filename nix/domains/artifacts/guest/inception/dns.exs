# @cc [owner:ghuntley,label:security;recovery] inception-local-dns-identity
# DNS bootstrap MUST sync its own local token before creating authority, verify
# an existing private file, and use ensure rather than rotation. A missing or
# changed credential MUST NOT revive or replace an existing service identity.
Application.put_env(:marshall, :operator_mode, true)
{:ok, _} = Application.ensure_all_started(:marshall)

result =
  Marshall.Operations.Privacy.run(fn ->
    path = "/var/lib/inception/dns.token"

    prepared =
      case File.lstat(path) do
        {:error, :enoent} ->
          Marshall.Operations.PrivateFiles.with_new(path, fn file ->
            {token, _} = Marshall.Ingress.Token.issue()
            Marshall.Operations.PrivateFiles.write_sync(file, path, token)
          end)

        {:ok, _} ->
          :ok

        _ ->
          {:error, :private_file_unavailable}
      end

    with :ok <- prepared,
         {:ok, token} <- Marshall.Operations.PrivateFiles.read(path),
         {:ok, _} <- Marshall.Ingress.Token.digest(token),
         {:ok, _} <-
           Marshall.Ingress.ensure_service(
             %{name: "inception-dns", role: :dns, token: token},
             actor: Marshall.Authorization.SystemActor.compute()
           ) do
      :ok
    else
      _ -> {:error, :dns_authority_unavailable}
    end
  end)

if result != :ok, do: System.halt(1)
