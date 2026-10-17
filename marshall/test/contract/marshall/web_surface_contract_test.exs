defmodule MarshallWebSurfaceContractTest do
  use Covenant.Case, component: "marshall.web_surface"

  @tag obligation: "marshall.web_surface.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      MarshallWeb,
      MarshallWeb.Admin.AccessLive,
      MarshallWeb.Admin.AuditLive,
      MarshallWeb.Admin.GitLive,
      MarshallWeb.Admin.JobsLive,
      MarshallWeb.Admin.LillyNodesLive,
      MarshallWeb.Admin.OperationsLive,
      MarshallWeb.Admin.UsersLive,
      MarshallWeb.Admin.WorkloadsLive,
      MarshallWeb.AdminElevation,
      MarshallWeb.AgentCLIApprovalLive,
      MarshallWeb.AgentCLIController,
      MarshallWeb.AgentThreadsLive,
      MarshallWeb.AudiLoginController,
      MarshallWeb.AuthController,
      MarshallWeb.AuthOverrides,
      MarshallWeb.AuthText,
      MarshallWeb.AuthenticationPrivacy,
      MarshallWeb.AutomaticMagicSignInLive,
      MarshallWeb.CloneComponents,
      MarshallWeb.ControlAPI,
      MarshallWeb.CoreComponents,
      MarshallWeb.DatabaseWait,
      MarshallWeb.DocsController,
      MarshallWeb.DocsHTML,
      MarshallWeb.EditorController,
      MarshallWeb.Endpoint,
      MarshallWeb.ErrorHTML,
      MarshallWeb.ErrorJSON,
      MarshallWeb.FleetEndpoint,
      MarshallWeb.Gettext,
      MarshallWeb.GitLive,
      MarshallWeb.GitRawController,
      MarshallWeb.HLDDLive,
      MarshallWeb.Health,
      MarshallWeb.InferenceExportController,
      MarshallWeb.InferenceLive,
      MarshallWeb.IngressAPI,
      MarshallWeb.IngressKnownHosts,
      MarshallWeb.IntegrationsLive,
      MarshallWeb.LaunchLive,
      MarshallWeb.Layouts,
      MarshallWeb.LiveAdminAuth,
      MarshallWeb.LiveSocket,
      MarshallWeb.LiveUserAuth,
      MarshallWeb.MachineDefaults,
      MarshallWeb.MachineWorkspace,
      MarshallWeb.MachinesLive,
      MarshallWeb.MarvinDownloadController,
      MarshallWeb.ObservedRouter,
      MarshallWeb.OverallsController,
      MarshallWeb.OverallsInstaller,
      MarshallWeb.OverviewLive,
      MarshallWeb.PageController,
      MarshallWeb.PageHTML,
      MarshallWeb.PendingLaunch,
      MarshallWeb.ProvisionerAPI,
      MarshallWeb.PublicIngress,
      MarshallWeb.RepositoryLaunchController,
      MarshallWeb.ResizeLive,
      MarshallWeb.Router,
      MarshallWeb.SSHAPI,
      MarshallWeb.SSHApprovalLive,
      MarshallWeb.SSHApprovalLogin,
      MarshallWeb.SSHKeysLive,
      MarshallWeb.SecurityLive,
      MarshallWeb.TeamsLive,
      MarshallWeb.Telemetry,
      MarshallWeb.TerminalLive,
      MarshallWeb.TerminalLogFilter,
      MarshallWeb.TerminalNames,
      MarshallWeb.TerminalOpening,
      MarshallWeb.TerminalPeerAPI,
      MarshallWeb.TerminalSocket,
      MarshallWeb.ThreadCommands,
      MarshallWeb.ThreadsLive,
      MarshallWeb.WorkspaceComponents
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "marshall.web_surface.I2"
  test "live health probe is fixed and uncached" do
    conn = Plug.Test.conn(:get, "/health/live") |> MarshallWeb.Health.call([])
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert conn.resp_body == "ok\n"

    head = Plug.Test.conn(:head, "/health/live") |> MarshallWeb.Health.call([])
    assert head.status == 200
    assert head.resp_body == ""
  end
end
