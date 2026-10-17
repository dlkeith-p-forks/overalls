# @cc [owner:ghuntley,label:security;recovery] inception-porsche-local-authority
# Bootstrap MUST prepare a private local credential before registering authority.
# Retries MUST preserve the enabled gateway identity and MUST NOT rotate or
# resurrect revoked authority. Parent credentials MUST NOT be used for Porsche.
Application.put_env(:marshall, :operator_mode, true)
{:ok, _} = Application.ensure_all_started(:marshall)

result =
  Marshall.Operations.Privacy.run(fn ->
    path = "/var/lib/inception/porsche.token"

    prepared =
      case File.lstat(path) do
        {:error, :enoent} ->
          case Marshall.Operations.SSHGateway.prepare(path) do
            {:ok, _} -> :ok
            _ -> {:error, :prepare_failed}
          end

        {:ok, _} ->
          :ok

        _ ->
          {:error, :private_file_unavailable}
      end

    with :ok <- prepared,
         {:ok, _} <- Marshall.Operations.SSHGateway.ensure("inception-porsche", path) do
      :ok
    else
      _ -> {:error, :porsche_authority_unavailable}
    end
  end)

if result != :ok, do: System.halt(1)
