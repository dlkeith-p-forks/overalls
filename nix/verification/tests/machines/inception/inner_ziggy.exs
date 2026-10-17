# @cc [owner:ghuntley,label:verification] inception-native-ziggy-authority
# This probe MUST authenticate the actual inner token against inner Marshall,
# verify its host binding and retry without extending expiry. It MUST NOT print
# token contents or treat enrollment as provider or private-frontend acceptance.
Application.put_env(:marshall, :operator_mode, true)
{:ok, _} = Application.ensure_all_started(:marshall)

result = Marshall.Operations.Privacy.run(fn ->
  with {:ok, runtime} <- Marshall.Operations.PrivateFiles.read("/var/lib/inception/lilly.json"),
       {:ok, %{"host_id" => host}} <- JSON.decode(runtime),
       {:ok, token} <- Marshall.Operations.PrivateFiles.read("/var/lib/inception/ziggy.token"),
       {:ok, %{host_id: ^host, credential_id: id}} <- Marshall.Inference.Credentials.authenticate(token),
       [before] <- Marshall.Compute.Ledger.read!(Marshall.Inference.Credential, id: id),
       {:ok, %{credential_id: ^id, expires_at: expiry}} <- Marshall.Inference.Credentials.ensure(host, token, 60),
       true <- expiry == before.expires_at,
       [after_retry] <- Marshall.Compute.Ledger.read!(Marshall.Inference.Credential, id: id),
       true <- after_retry == before do
    :ok
  else
    _ -> :error
  end
end)

if result != :ok, do: System.halt(1)
