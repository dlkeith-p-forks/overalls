defmodule CertificateServer do
  @moduledoc "Native OTP/OpenSSH certificate interoperability fixture."
  @spec run() :: no_return()
  def run do
    :ok = :ssh.start()
    {:ok, _} = :ssh.daemon({0, 0, 0, 0}, 2222,
      system_dir: ~c"/run/certificate-server", user_dir: ~c"/run/certificate-server",
      preferred_algorithms: [public_key: [:"ssh-ed25519-cert-v01@openssh.com"] ++ :ssh.default_algorithms()[:public_key]],
      auth_methods: ~c"publickey", shell: :disabled, subsystems: [],
      exec: {:direct, fn _command, _user -> {:ok, String.duplicate("certified\n", 8192)} end})
    Process.sleep(:infinity)
  end
end
CertificateServer.run()
