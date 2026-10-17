defmodule Overalls.BrowserTerminalProbe do
  @moduledoc "Optional Chromium acceptance over the same HTTPS endpoint and real guest."

  def run(options, base_url, vm, owner, member) do
    if python = options[:browser_python] do
      strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
      {:ok, owner_token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, owner)

      {:ok, member_token} =
        AshAuthentication.Strategy.MagicLink.request_token_for(strategy, member)

      {:ok, _} =
        Marshall.Access.set_access(
          %{
            vm_id: vm.id,
            email: to_string(member.email),
            role: :viewer,
            idempotency_key: Ash.UUID.generate()
          },
          actor: owner
        )

      context = %{
        base_url: base_url,
        owner_url: base_url <> "/magic_link/" <> owner_token,
        member_url: base_url <> "/magic_link/" <> member_token,
        member_email: to_string(member.email),
        vm_id: vm.id,
        artifacts: options[:browser_artifacts]
      }

      port =
        Port.open({:spawn_executable, Path.expand(python)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [Path.expand("browser_terminal_probe.py", __DIR__)]
        ])

      # Login links travel through a private pipe, never arguments or console output.
      Port.command(port, JSON.encode!(context) <> "\n")

      try do
        await(port, System.monotonic_time(:millisecond) + 180_000)
      after
        if Port.info(port), do: Port.close(port)

        for token <- [owner_token, member_token] do
          {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

          Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM tokens WHERE jti=$1", [jti],
            log: false
          )
        end
      end

      IO.puts(
        "Browser terminal v2: Chromium sign-in, guest commands, explicit view-only sharing, revocation, reconnect, clipboard consent and mobile layout passed."
      )
    end
  end

  defp await(port, deadline) do
    receive do
      {^port, {:data, data}} ->
        # The probe deliberately prints only fixed stage names and status.
        IO.write(data)
        await(port, deadline)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, _}} ->
        raise "browser terminal probe failed"
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        raise "browser terminal probe timed out"
    end
  end
end
