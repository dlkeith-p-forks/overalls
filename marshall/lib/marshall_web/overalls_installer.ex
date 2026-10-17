defmodule MarshallWeb.OverallsInstaller do
  @moduledoc "Deployment-bound public SSH CA installers (POSIX shell and Windows PowerShell)."
  @external_resource Path.expand("../../priv/overalls-install.sh", __DIR__)
  @external_resource Path.expand("../../priv/overalls-install.ps1", __DIR__)
  @shell File.read!(Path.expand("../../priv/overalls-install.sh", __DIR__))
  @powershell File.read!(Path.expand("../../priv/overalls-install.ps1", __DIR__))

  @type kind :: :shell | :powershell

  # @cc [owner:ghuntley,label:security] installer-deployment-trust
  # Only validated operator host/zone policy may select installer substitutions,
  # for both the shell and the PowerShell installer. Missing trust MUST disable
  # the installer; request headers cannot choose it.
  @spec render(term(), term(), kind()) :: {:ok, binary()} | :error
  def render(host, policy, kind \\ :shell) when kind in [:shell, :powershell] do
    with {:ok, trust} <- OverallsProtocol.SSHTrust.parse(policy),
         true <- host == trust.management_host do
      {:ok,
       script(kind)
       |> String.replace("@OVERALLS_MANAGEMENT_HOST@", host)
       |> String.replace("@OVERALLS_GUEST_ZONE@", trust.zone)}
    else
      _ -> :error
    end
  end

  @spec script(kind()) :: binary()
  defp script(:shell), do: @shell
  defp script(:powershell), do: @powershell
end
