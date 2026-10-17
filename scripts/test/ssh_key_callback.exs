defmodule Overalls.TestSSHKeyCallback do
  @moduledoc "Raw-key transport for OTP-client channel unit tests; production uses native certificates."
  @behaviour :ssh_server_key_api
  @impl true
  def host_key(:"ssh-ed25519" = algorithm, options), do: :ssh_file.host_key(algorithm, options)
  def host_key(_, _), do: {:error, :unsupported_host_key}
  @impl true
  def is_auth_key(key, username, options) do
    options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:proof)
    |> apply(:is_auth_key, [key, username, options])
  end
end
