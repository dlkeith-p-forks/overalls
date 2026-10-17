# @cc [owner:ghuntley,label:security;recovery] inception-independent-ziggy-enrollment
# Bootstrap MUST sync a fresh instance-local Ziggy token before enrolling it.
# Retries MUST verify exactly that authority without extending expiry. Missing
# custody MUST NOT replace enrolled identity or revive revoked credentials. Parent/provider credentials
# MUST NOT enter this token or the inner Marshall database. Diagnostics stay closed.
result = Marshall.Operations.Privacy.run(fn ->
  path = "/var/lib/inception/ziggy.token"
  prepared = case File.lstat(path) do
    {:error, :enoent} ->
      Marshall.Operations.PrivateFiles.with_new(path, fn file ->
        token = Ash.UUID.generate() <> "." <>
          Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        Marshall.Operations.PrivateFiles.write_sync(file, path, token)
      end)
    {:ok, _} -> :ok
    _ -> {:error, :private_file_unavailable}
  end

  with :ok <- prepared,
       {:ok, runtime} <- Marshall.Operations.PrivateFiles.read("/var/lib/inception/lilly.json"),
       {:ok, %{"host_id" => host}} <- JSON.decode(runtime),
       {:ok, token} <- Marshall.Operations.PrivateFiles.read(path),
       {:ok, _} <- Marshall.Inference.Credentials.ensure(host, token, 5 * 365 * 86_400) do
    :ok
  else
    _ -> {:error, :ziggy_authority_unavailable}
  end
end)

if result != :ok, do: System.halt(1)
