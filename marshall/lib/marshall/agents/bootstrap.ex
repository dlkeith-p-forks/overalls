defmodule Marshall.Agents.Bootstrap do
  @moduledoc "Durable fixed-program bootstrap for retained executors, separate from user conversations."
  alias Marshall.Agents.{ExecutorSession, ToolBootstrap, ToolMaintenance}
  alias Marshall.Compute.{Image, Ledger}
  require Marshall.Events
  @type binding :: OverallsProtocol.PrivateServices.binding()
  @type envelope :: %{id: String.t(), call_id: String.t(), tool: :exec_command, arguments: map()}

  # @cc [owner:ghuntley,label:security;recovery] executor-bootstrap-fixed-program
  # Retained executors MUST receive only a current-platform, digest-bound helper
  # through a separate durable receipt. Neither a user turn nor model output may
  # select the program, origin, arguments or identity. Claims/start/artifacts and
  # completion MUST revalidate the live executor and current execution; only a
  # completed desired tool receipt establishes bootstrap success. Bounded failures
  # MAY retry using verified public artifacts without replaying GitHub mutations.

  # @cc [owner:ghuntley,label:recovery] executor-bootstrap-claim-idempotency
  # Repeated claims by the same current executor and fence MUST return the same
  # unstarted attempt. A repeated poll MUST NOT invalidate its later start receipt.
  @spec claim_locked!(binding(), String.t(), pos_integer()) :: envelope() | nil
  def claim_locked!(binding, id, fence) do
    {executor, vm} = ExecutorSession.maintenance_lease!(binding, id, fence)

    with false <- "github-tools-v1" in executor.capabilities,
         {:ok, release} <- Marshall.Operations.ExecutorBootstrap.load(),
         {:ok, tools} <- Marshall.Operations.GitHubTools.load() do
      platform = platform!(vm)
      artifact = Map.fetch!(release.platforms, platform)

      generation =
        :crypto.hash(:sha256, tools.generation <> artifact.sha256) |> Base.encode16(case: :lower)

      attrs = %{
        vm_id: vm.id,
        generation: generation,
        platform: platform,
        tools_generation: tools.generation,
        artifact_sha256: artifact.sha256,
        artifact_bytes: artifact.bytes
      }

      row =
        case find!(vm.id) do
          nil -> Ledger.create!(ToolBootstrap, :queue, attrs)
          %{generation: ^generation} = row -> row
          row -> reset!(row, attrs)
        end

      row =
        if row.executor_id && (row.executor_id != id or row.fence_epoch != fence),
          do: reset!(row, attrs),
          else: row

      cond do
        row.phase == :completed ->
          nil

        row.phase == :claimed ->
          envelope(row)

        row.phase == :started and DateTime.diff(Ledger.now(), row.updated_at) < 30 ->
          nil

        row.phase == :failed and DateTime.diff(Ledger.now(), row.updated_at) < 2 ->
          nil

        true ->
          row =
            if row.phase in [:started, :claimed] do
              uncertain = Ledger.update!(row, :uncertain, %{})
              log_transition(uncertain)
              uncertain
            else
              row
            end

          row = if row.phase in [:failed, :uncertain], do: reset!(row, attrs), else: row
          retry_installation!(vm.id, tools.generation)

          row =
            Ledger.update!(row, :claim, %{
              attempt_id: Ash.UUID.generate(),
              executor_id: id,
              fence_epoch: fence,
              placement_id: vm.current_placement_id,
              execution_epoch: vm.execution_epoch
            })

          log_transition(row)
          envelope(row)
      end
    else
      _ -> nil
    end
  end

  @spec envelope(ToolBootstrap.t()) :: envelope()
  defp envelope(row) do
    %{
      id: row.attempt_id,
      call_id: "executor-bootstrap",
      tool: :exec_command,
      arguments: %{"cmd" => script(row)}
    }
  end

  @spec transition_locked!(binding(), String.t(), pos_integer(), String.t(), atom(), map()) ::
          {:ok, map()} | :not_bootstrap
  def transition_locked!(binding, id, fence, attempt_id, state, _result) do
    case attempt!(attempt_id) do
      nil ->
        :not_bootstrap

      row ->
        {_executor, vm} = ExecutorSession.maintenance_lease!(binding, id, fence)
        validate!(row, vm, id, fence)
        previous_phase = row.phase

        row =
          case {state, row.phase} do
            {:started, :claimed} ->
              Ledger.update!(row, :start, %{})

            {:started, :started} ->
              row

            {:completed, :started} ->
              Ledger.update!(row, if(installed?(row), do: :complete, else: :fail), %{})

            {:completed, :completed} ->
              row

            {state, phase}
            when state in [:failed, :uncertain] and phase in [:claimed, :started] ->
              Ledger.update!(row, if(state == :failed, do: :fail, else: :uncertain), %{})

            {:failed, :failed} ->
              row

            _ ->
              Ledger.rollback(:invalid_transition)
          end

        if row.phase != previous_phase, do: log_transition(row)
        {:ok, %{command_id: row.attempt_id, status: row.phase}}
    end
  end

  @spec artifact_locked!(binding(), String.t(), pos_integer(), String.t(), String.t()) :: map()
  def artifact_locked!(binding, id, fence, attempt_id, digest) do
    {_executor, vm} = ExecutorSession.maintenance_lease!(binding, id, fence)
    row = attempt!(attempt_id) || Ledger.rollback(:stale_fence)
    validate!(row, vm, id, fence)

    unless row.phase == :started and row.artifact_sha256 == digest,
      do: Ledger.rollback(:unauthorized)

    %{sha256: row.artifact_sha256, bytes: row.artifact_bytes}
  end

  @spec authorized_locked?(String.t(), String.t(), pos_integer()) :: boolean()
  def authorized_locked?(vm_id, id, fence) do
    case find!(vm_id) do
      %{phase: :started, executor_id: ^id, fence_epoch: ^fence} = row ->
        current_release?(row) and DateTime.diff(Ledger.now(), row.updated_at) < 30

      _ ->
        false
    end
  end

  @spec attempt?(String.t()) :: boolean()
  def attempt?(id), do: Ledger.read!(ToolBootstrap, attempt_id: id) != []

  @spec requires_authority?(String.t()) :: boolean()
  def requires_authority?(id) do
    case Ledger.read!(Marshall.Agents.Executor, id: id) do
      [executor] -> "github-tools-v1" not in executor.capabilities
      _ -> false
    end
  end

  # @cc [owner:ghuntley,label:observability] bootstrap-committed-transition
  # Installation diagnostics MUST contain only safe identifiers and closed
  # phases, emit after the outer commit, and omit unchanged repeated receipts.
  @spec log_transition(ToolBootstrap.t()) :: :ok
  defp log_transition(row) do
    Ledger.after_commit(fn ->
      Marshall.Events.emit("agent.installation_transition",
        vm_id: row.vm_id,
        attempt_id: row.attempt_id,
        executor_id: row.executor_id,
        kind: :bootstrap,
        phase: row.phase
      )
    end)
  end

  defp retry_installation!(vm_id, generation) do
    case Ledger.read!(ToolMaintenance, vm_id: vm_id) do
      [%{generation: ^generation, phase: phase} = candidate] when phase != :completed ->
        row = Ledger.lock!(ToolMaintenance, candidate.id)

        Ledger.update!(row, :reset, %{
          generation: generation,
          platform: row.platform,
          attempt_id: nil,
          executor_id: nil,
          fence_epoch: nil,
          placement_id: nil,
          execution_epoch: nil,
          previous_generation: nil,
          outcome: nil
        })

      _ ->
        :ok
    end
  end

  defp installed?(row) do
    Enum.any?(Ledger.read!(ToolMaintenance, vm_id: row.vm_id), fn installed ->
      installed.phase == :completed and installed.generation == row.tools_generation and
        installed.executor_id == row.executor_id and installed.fence_epoch == row.fence_epoch
    end)
  end

  defp current_release?(row) do
    with {:ok, release} <- Marshall.Operations.ExecutorBootstrap.load(),
         {:ok, tools} <- Marshall.Operations.GitHubTools.load() do
      artifact = release.platforms[row.platform]

      artifact.sha256 == row.artifact_sha256 and artifact.bytes == row.artifact_bytes and
        tools.generation == row.tools_generation
    else
      _ -> false
    end
  end

  defp validate!(row, vm, id, fence) do
    unless row.vm_id == vm.id and row.executor_id == id and row.fence_epoch == fence and
             row.placement_id == vm.current_placement_id and
             row.execution_epoch == vm.execution_epoch and
             current_release?(row),
           do: Ledger.rollback(:stale_fence)
  end

  defp platform!(vm) do
    [image] = Ledger.read!(Image, id: vm.image_id)

    case Image.guest_agents_capability(image) do
      {:ok, :linux} -> "linux-amd64"
      {:ok, :windows_v1} -> "windows-amd64"
      {:ok, :freebsd_v1} -> "freebsd-amd64"
      {:ok, :illumos_v1} -> "illumos-amd64"
      _ -> Ledger.rollback(:unavailable)
    end
  end

  defp reset!(row, attrs) do
    Ledger.update!(
      row,
      :reset,
      Map.drop(attrs, [:vm_id])
      |> Map.merge(%{
        attempt_id: nil,
        executor_id: nil,
        fence_epoch: nil,
        placement_id: nil,
        execution_epoch: nil
      })
    )
  end

  defp find!(vm_id) do
    case Ledger.read!(ToolBootstrap, vm_id: vm_id) do
      [row] -> Ledger.lock!(ToolBootstrap, row.id)
      [] -> nil
    end
  end

  defp attempt!(id) do
    case Ledger.read!(ToolBootstrap, attempt_id: id) do
      [row] -> Ledger.lock!(ToolBootstrap, row.id)
      [] -> nil
    end
  end

  # All substitutions come from typed, validated resources/inventories. Scripts
  # contain no credentials; the shared installer revalidates the same live lease.
  defp script(%{platform: "windows-amd64"} = row) do
    url = url(row)

    """
    $ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
    $root='C:\\ProgramData\\Overalls\\ExecutorBootstrap'
    foreach ($directory in @('C:\\ProgramData\\Overalls',$root)) {
      [System.IO.Directory]::CreateDirectory($directory) | Out-Null
      if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 }
    }
    $acl=New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('O:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    [System.IO.Directory]::SetAccessControl($root,$acl)
    $file=Join-Path $root '#{row.artifact_sha256}.exe'
    if (!(Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -ne #{row.artifact_bytes} -or (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant() -ne '#{row.artifact_sha256}') {
      Add-Type -AssemblyName System.Net.Http
      $handler=New-Object System.Net.Http.HttpClientHandler; $handler.UseProxy=$false; $handler.AllowAutoRedirect=$false
      $client=New-Object System.Net.Http.HttpClient($handler); $client.Timeout=[TimeSpan]::FromSeconds(8)
      $response=$client.GetAsync('#{url}',[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      if ($response.StatusCode -ne 200) { exit 1 }
      $input=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $stage=Join-Path $root ([Guid]::NewGuid().ToString()+'.stage'); $output=[IO.File]::Open($stage,[IO.FileMode]::CreateNew)
      try { $buffer=New-Object byte[] 65536; $total=0; $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while (($count=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
          $total+=$count; if ($total -gt #{row.artifact_bytes} -or [DateTime]::UtcNow -gt $deadline) { throw 'invalid artifact' }
          $output.Write($buffer,0,$count)
        }; $output.Flush($true)
      } finally { $output.Dispose(); $input.Dispose(); $response.Dispose(); $client.Dispose() }
      if ($total -ne #{row.artifact_bytes} -or (Get-FileHash -Algorithm SHA256 -LiteralPath $stage).Hash.ToLowerInvariant() -ne '#{row.artifact_sha256}') { Remove-Item -LiteralPath $stage; exit 1 }
      Move-Item -LiteralPath $stage -Destination $file -Force
    }
    & $file __github-tools-bootstrap '#{row.executor_id}' '#{row.fence_epoch}'; exit $LASTEXITCODE
    """
  end

  defp script(row) do
    hash =
      case row.platform do
        "freebsd-amd64" -> "/sbin/sha256 -q"
        "illumos-amd64" -> "/usr/bin/digest -a sha256"
        _ -> "sha256sum"
      end

    """
    set -eu
    umask 077
    root=/var/lib/overalls/executor-bootstrap
    test ! -L /var/lib/overalls
    mkdir -p /var/lib/overalls
    test "$(ls -dn /var/lib/overalls | awk '{print $3}')" = 0
    chmod 0755 /var/lib/overalls
    mkdir -p "$root"; test ! -L "$root"
    test "$(ls -dn "$root" | awk '{print $3}')" = 0
    chmod 0700 "$root"
    file="$root/#{row.artifact_sha256}"
    if [ ! -f "$file" ] || [ "$(#{hash} "$file" | cut -d ' ' -f1)" != '#{row.artifact_sha256}' ]; then
      stage=$(mktemp "$root/stage.XXXXXXXX")
      trap 'rm -f "$stage"' EXIT HUP INT TERM
      #{download(row)}
      test "$(wc -c < "$stage" | tr -d ' ')" = '#{row.artifact_bytes}'
      test "$(#{hash} "$stage" | cut -d ' ' -f1)" = '#{row.artifact_sha256}'
      chmod 0700 "$stage"; mv -f "$stage" "$file"
      trap - EXIT HUP INT TERM
    fi
    exec "$file" __github-tools-bootstrap '#{row.executor_id}' '#{row.fence_epoch}'
    """
  end

  @spec download(ToolBootstrap.t()) :: String.t()
  defp download(%{platform: "linux-amd64"} = row) do
    """
    python3 -I - "$stage" <<'PYTHON'
    import ssl
    import sys
    import time
    from http.client import HTTPMessage
    from typing import BinaryIO
    from urllib.request import HTTPRedirectHandler, HTTPSHandler, ProxyHandler, Request, build_opener
    class RefuseRedirect(HTTPRedirectHandler):
        def redirect_request(self, req: Request, fp: BinaryIO, code: int, msg: str, headers: HTTPMessage, newurl: str) -> None:
            return None
    opener = build_opener(ProxyHandler({}), HTTPSHandler(context=ssl.create_default_context()), RefuseRedirect())
    deadline: float = time.monotonic() + 8
    total: int = 0
    with opener.open(Request('#{url(row)}', headers={"Connection": "close"}), timeout=6) as response, open(sys.argv[1], 'wb') as output:
        if response.status != 200: raise ValueError("invalid artifact")
        while chunk := response.read(65536):
            total += len(chunk)
            if total > #{row.artifact_bytes} or time.monotonic() > deadline: raise ValueError("invalid artifact")
            output.write(chunk)
        output.flush()
    PYTHON
    """
  end

  defp download(row) do
    "curl -q --proxy '' --proto '=https' --connect-timeout 3 --max-time 8 --max-filesize #{row.artifact_bytes} --fail --silent --output \"$stage\" '#{url(row)}'"
  end

  defp url(row) do
    "https://llm.internal/agent/v1/bootstrap/artifacts/#{row.artifact_sha256}" <>
      "?executor_id=#{row.executor_id}&fence_epoch=#{row.fence_epoch}&bootstrap_id=#{row.attempt_id}"
  end
end
