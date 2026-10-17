# @cc [owner:ghuntley,label:verification] ssh-fixture-uses-live-permit-authorizer
# OpenSSH supplies these public authentication fields. The fixture MUST use the
# production durable key lookup and forced-command generator; a fixture key file
# MUST NOT bypass permit expiry/revocation or substitute the authenticated key.
case {System.get_env("EXPORT_USER"), System.get_env("EXPORT_TYPE"), System.get_env("EXPORT_KEY")} do
  {"lilly-transfer", "ssh-ed25519", encoded} when is_binary(encoded) ->
    case Lilly.Transfer.ExportRequest.authorized_key(
           "/run/source-permits",
           "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
           "ssh-ed25519 " <> encoded,
           "/etc/transfer-export",
           System.system_time(:second)
         ) do
      {:ok, line} -> IO.binwrite(:stdio, line)
      _ -> System.halt(1)
    end

  _ ->
    System.halt(1)
end
