defmodule MarshallSshTerminalContractTest do
  use Covenant.Case, component: "marshall.ssh_terminal"

  @tag obligation: "marshall.ssh_terminal.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Marshall.SSH,
      Marshall.SSH.AdminActions,
      Marshall.SSH.Approval,
      Marshall.SSH.Authority,
      Marshall.SSH.Commands,
      Marshall.SSH.ControlRequests,
      Marshall.SSH.Error,
      Marshall.SSH.Gateway,
      Marshall.SSH.GuestAccess,
      Marshall.SSH.GuestLogin,
      Marshall.SSH.HostCertificate,
      Marshall.SSH.HostCertificateRetention,
      Marshall.SSH.HostCertificates,
      Marshall.SSH.Key,
      Marshall.SSH.KeyActions,
      Marshall.SSH.KeyRegistry,
      Marshall.SSH.Request,
      Marshall.SSH.Retention,
      Marshall.SSH.Session,
      Marshall.SSH.Token,
      Marshall.Terminal,
      Marshall.Terminal.Authority,
      Marshall.Terminal.Creation,
      Marshall.Terminal.Directory,
      Marshall.Terminal.Event,
      Marshall.Terminal.Grant,
      Marshall.Terminal.HostStream,
      Marshall.Terminal.Location,
      Marshall.Terminal.Metrics,
      Marshall.Terminal.Opening,
      Marshall.Terminal.PeerBudget,
      Marshall.Terminal.PeerSocket,
      Marshall.Terminal.Reconciler,
      Marshall.Terminal.Relay,
      Marshall.Terminal.Remote,
      Marshall.Terminal.Session,
      Marshall.Terminal.Sharing,
      Marshall.Terminal.Termination,
      Marshall.Terminal.Ticket,
      Marshall.Terminal.TicketRetention,
      Marshall.Terminal.Tickets,
      Marshall.Terminal.Viewer,
      Marshall.Terminal.ViewerAuthority
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
