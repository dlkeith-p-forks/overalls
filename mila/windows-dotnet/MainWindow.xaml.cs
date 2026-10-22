using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Mila.Windows.Interop;
namespace Mila.Windows;
public sealed partial class MainWindow : Window
{
    private string? _activeHost;
    private bool _notificationsEnabled;
    public MainWindow()
    {
        InitializeComponent();
        ApplyStrings();
        if (MilaDeploymentStore.Load() is { } deployment) { DeploymentHost.Text = deployment.Host; _activeHost = deployment.Host; }
        Navigation.SelectedItem = Navigation.MenuItems[0];
    }
    private static string S(string id, string fallback) => MilaStrings.Text(id, fallback);
    private void ApplyStrings()
    {
        ((NavigationViewItem)Navigation.MenuItems[0]).Content = S("machinesTitle", "Machines");
        ((NavigationViewItem)Navigation.MenuItems[1]).Content = S("tabThreads", "Threads");
        ((NavigationViewItem)Navigation.MenuItems[2]).Content = S("settingsTitle", "Settings");
        PageTitle.Text = S("machinesTitle", "Machines");
        PageBody.Text = S("machinesEmpty", "Select a machine to view its status.");
        StatusText.Text = S("ready", "Ready");
        DeploymentHostLabel.Text = S("deploymentHostLabel", "Deployment host");
        DeploymentHost.PlaceholderText = S("deploymentHostHint", "overalls.example");
        ConnectDeployment.Content = S("signInStart", "Sign in in browser");
        MachineCommandsTitle.Text = S("machineMore", "Machine commands");
        MachineCommandsHelp.Text = S("machineAccess", "Commands are classified by the Rust core before execution.");
        MachineList.Content = S("tabInfo", "List"); MachineShow.Content = S("machineLoading", "Show");
        MachineNew.Content = S("actionNew", "New"); MachineResize.Content = S("actionResize", "Resize");
        MachineStart.Content = S("actionStart", "Start"); MachineStop.Content = S("actionStop", "Stop");
        MachinePause.Content = S("actionPause", "Pause"); MachineResume.Content = S("actionResume", "Resume");
        MachineDelete.Content = S("actionDelete", "Delete"); MachineShareAdd.Content = S("sharingAdd", "Share add");
        MachineShareRemove.Content = S("sharingRemove", "Share remove"); MachineWebShow.Content = S("webOpen", "Web show");
        MachineWebSet.Content = S("webSave", "Web set");
        CreateMachine.Content = S("actionCreate", "Create machine");
        ShareAdd.Content = S("sharingAdd", "Share add");
        ShareRemove.Content = S("sharingRemove", "Share remove");
        SshKeysTitle.Text = S("sshKeysTitle", "SSH keys");
        SshKeysStatus.Text = S("sshKeysSignInFirst", "Sign in to manage SSH keys.");
        RefreshSshKeys.Content = S("refresh", "Refresh");
        ThreadCommandsTitle.Text = S("tabThreads", "Thread commands");
        ThreadCommandsHelp.Text = S("threadWorking", "Commands are validated by the Rust core before execution.");
        ThreadList.Content = S("tabInfo", "List"); ThreadShow.Content = S("machineLoading", "Show");
        ThreadTurns.Content = S("threadEventTurnStarted", "Turns"); ThreadRead.Content = S("threadEventOther", "Read");
        Refresh.Content = S("refresh", "Refresh");
        LockButton.Content = S("lockTitle", "Lock app");
        LockStatus.Text = S("lockUnavailable", "App lock is unavailable until Windows Hello is configured.");
        TerminalTitle.Text = S("tabTerminals", "Terminal");
        TerminalAttach.Content = S("terminalAttach", "Attach");
        TerminalResize.Content = S("terminalModeControl", "Resize");
        TerminalInput.Content = S("terminalPaste", "Send input");
        NotificationsButton.Content = S("notificationsTurnOn", "Turn notifications on");
        NotificationsStatus.Text = S("pushStateOff", "Notifications off");
        WebOpen.Content = S("webOpen", "Open web");
        WebCopy.Content = S("webCopy", "Copy address");
        WebStatus.Text = S("webNoAddress", "No web address");
    }
    private void RefreshSshKeys(object sender, RoutedEventArgs args)
    {
        SshKeysStatus.Text = _activeHost is null
            ? S("sshKeysSignInFirst", "Sign in to manage SSH keys.")
            : S("sshKeysLoading", "Loading SSH keys…");
    }
    private void ShareMachine(object sender, RoutedEventArgs args) => ClassifyMachine($"share add {SampleMachine} user viewer");
    private void UnshareMachine(object sender, RoutedEventArgs args) => ClassifyMachine($"share remove {SampleMachine} user");
    private void CreateMachine(object sender, RoutedEventArgs args)
    {
        MilaMachineCommandKind? kind = RustNative.TryClassifyMachineCommand("new");
        MachineCommandStatus.Text = kind == MilaMachineCommandKind.New
            ? S("requestWaiting", "Create request validated by Rust")
            : S("requestRefused", "Create request refused");
    }
    private void OpenWebControl(object sender, RoutedEventArgs args)
    {
        MilaMachineCommandKind? kind = RustNative.TryClassifyMachineCommand($"web show {SampleMachine}");
        WebStatus.Text = kind == MilaMachineCommandKind.WebShow
            ? S("webVisibility", "Web control validated")
            : S("webFailed", "Web control unavailable");
    }
    private void CopyWebAddress(object sender, RoutedEventArgs args)
    {
        MilaMachineCommandKind? kind = RustNative.TryClassifyMachineCommand($"web show {SampleMachine}");
        WebStatus.Text = kind == MilaMachineCommandKind.WebShow
            ? S("webCopied", "Web address copied")
            : S("webFailed", "Web control unavailable");
    }
    private void ToggleNotifications(object sender, RoutedEventArgs args)
    {
        _notificationsEnabled = !_notificationsEnabled;
        MilaNativePokeResult result = RustNative.TryValidatePushPoke(ReadOnlySpan<byte>.Empty, (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        NotificationsStatus.Text = result.IsValid
            ? (_notificationsEnabled ? S("pushStateOn", "Notifications on") : S("pushStateOff", "Notifications off"))
            : S("pushUnsupported", "Notifications unavailable");
        NotificationsButton.Content = _notificationsEnabled ? S("notificationsTurnOff", "Turn notifications off") : S("notificationsTurnOn", "Turn notifications on");
    }
    private void ValidateTerminalAttach(object sender, RoutedEventArgs args)
    {
        MilaNativeTerminalResult result = RustNative.TryValidateTerminalAttach(0, 80, 24, true);
        TerminalStatus.Text = result.IsValid ? S("terminalAttaching", "Attaching…") : S("terminalRefused", "Terminal refused");
    }
    private void ValidateTerminalResize(object sender, RoutedEventArgs args)
    {
        MilaNativeTerminalResult result = RustNative.TryValidateTerminalResize(80, 24, true);
        TerminalStatus.Text = result.IsValid ? S("terminalLive", "Terminal live") : S("terminalInvalid", "Invalid terminal dimensions");
    }
    private void ValidateTerminalInput(object sender, RoutedEventArgs args)
    {
        MilaNativeTerminalResult result = RustNative.TryValidateTerminalInput(0, true);
        TerminalStatus.Text = result.IsValid ? S("terminalLive", "Terminal live") : S("terminalReadOnly", "Terminal is read only");
    }
    private void ConnectToDeployment(object sender, RoutedEventArgs args)
    {
        string host = DeploymentHost.Text.Trim();
        if (host.Length == 0)
        {
            StatusText.Text = S("invalidHost", "Enter a valid deployment host.");
            return;
        }
        StatusText.Text = S("signInConnecting", "Connecting to deployment…").Replace("{host}", host, StringComparison.Ordinal);
        ConnectDeployment.IsEnabled = false;
        _ = ConnectDeploymentAsync(host);
    }
    private async Task ConnectDeploymentAsync(string host)
    {
        await Task.Delay(150);
        MilaNativeVersionResult result = RustNative.TryGetVersion();
        if (result.Status == MilaNativeStatus.Ok)
        {
            _activeHost = host;
            MilaDeploymentStore.Save(new MilaDeployment(host));
            StatusText.Text = S("signInApprove", "Approve this device in your browser, then return here.");
            RefreshMachines();
        }
        else
        {
            _activeHost = null;
            StatusText.Text = S("signInFailedUnreachable", "Unable to connect to deployment.");
        }
        ConnectDeployment.IsEnabled = true;
    }
    private void LockApp(object sender, RoutedEventArgs args)
    {
        // Keep the lock boundary explicit until a Windows Hello broker is wired in.
        Navigation.IsHitTestVisible = false;
        LockButton.Content = S("unlock", "Unlock");
        LockStatus.Text = S("lockedTitle", "Mila is locked") + " — " + S("lockReason", "Unlock Mila");
        LockButton.Click -= LockApp;
        LockButton.Click += UnlockApp;
    }
    private void UnlockApp(object sender, RoutedEventArgs args)
    {
        Navigation.IsHitTestVisible = true;
        LockButton.Content = S("lockTitle", "Lock app");
        LockStatus.Text = S("lockUnavailable", "App lock is unavailable until Windows Hello is configured.");
        LockButton.Click -= UnlockApp;
        LockButton.Click += LockApp;
    }
    private void OnNavigationChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item) {
            string tag = item.Tag?.ToString() ?? "machines";
            PageTitle.Text = item.Content?.ToString() ?? "Mila";
            PageBody.Text = tag switch { "threads" => S("threadsRecentTitle", "Recent conversations appear here."), "settings" => S("settingsOffline", "Runtime settings are managed by the core library."), _ => S("machinesEmpty", "Select a machine to view its status.") };
            ThreadPanel.Visibility = tag == "threads" ? Visibility.Visible : Visibility.Collapsed;
            MachineRows.Visibility = tag == "machines" ? Visibility.Visible : Visibility.Collapsed;
            MachinePanel.Visibility = tag == "machines" ? Visibility.Visible : Visibility.Collapsed;
        }
    }
    private void CheckNativeBridge(object sender, RoutedEventArgs args)
    {
        MilaNativeVersionResult result = RustNative.TryGetVersion();
        StatusText.Text = result.Status == MilaNativeStatus.Ok
            ? MilaStrings.Text("connected", MilaStrings.Connected)
            : MilaStrings.Text("runtimeUnavailable", MilaStrings.RuntimeUnavailable);
        RefreshMachines();
    }

    private void RefreshMachines()
    {
        MachineRows.ItemsSource = Array.Empty<MilaMachineRow>();
        if (_activeHost is { } host)
        {
            string savedAt = S("machinesSavedAt", "Machines for");
            string empty = S("machinesEmpty", "No machines");
            StatusText.Text = $"{savedAt} {host}: {empty}";
        }
    }
    private void OnMachineSelected(object sender, SelectionChangedEventArgs args)
    {
        if (MachineRows.SelectedItem is not MilaMachineRow machine) return;
        string access = machine.CanManage ? S("machineAccessOwner", "Manage") : machine.CanWrite ? S("machineAccessShared", "Write") : S("terminalReadOnly", "Read only");
        MachineCommandStatus.Text = $"{machine.Name} ({machine.DesiredState}) — {access}";
    }

    private void ClassifyThreadList(object sender, RoutedEventArgs args) => ClassifyThread("thread ls");
    private void ClassifyThreadShow(object sender, RoutedEventArgs args) => ClassifyThread("thread show");
    private void ClassifyThreadTurns(object sender, RoutedEventArgs args) => ClassifyThread("thread turns");
    private void ClassifyThreadRead(object sender, RoutedEventArgs args) => ClassifyThread("thread read");

    private void ClassifyThread(string command)
    {
        MilaNativeThreadCommandResult result = RustNative.TryClassifyThreadCommand(command);
        ThreadCommandStatus.Text = result.Status == MilaNativeStatus.Ok && result.Kind is { } kind
            ? $"{command}: {kind} (Rust)"
            : $"{command}: unavailable ({result.Status})";
    }

    private void ClassifyMachineList(object sender, RoutedEventArgs args) => ClassifyMachine("ls");
    private const string SampleMachine = "00000000-0000-0000-0000-000000000000";
    private void ClassifyMachineShow(object sender, RoutedEventArgs args) => ClassifyMachine("show demo");
    private void ClassifyMachineNew(object sender, RoutedEventArgs args) => ClassifyMachine("new");
    private void ClassifyMachineResize(object sender, RoutedEventArgs args) => ClassifyMachine($"resize {SampleMachine}");
    private void ClassifyMachineStart(object sender, RoutedEventArgs args) => ClassifyMachine($"start {SampleMachine}");
    private void ClassifyMachineStop(object sender, RoutedEventArgs args) => ClassifyMachine($"stop {SampleMachine}");
    private void ClassifyMachinePause(object sender, RoutedEventArgs args) => ClassifyMachine($"pause {SampleMachine}");
    private void ClassifyMachineResume(object sender, RoutedEventArgs args) => ClassifyMachine($"resume {SampleMachine}");
    private void ClassifyMachineDelete(object sender, RoutedEventArgs args) => ClassifyMachine($"rm {SampleMachine}");
    private void ClassifyMachineShareAdd(object sender, RoutedEventArgs args) => ClassifyMachine($"share add {SampleMachine} user viewer");
    private void ClassifyMachineShareRemove(object sender, RoutedEventArgs args) => ClassifyMachine($"share remove {SampleMachine} user");
    private void ClassifyMachineWebShow(object sender, RoutedEventArgs args) => ClassifyMachine($"web show {SampleMachine}");
    private void ClassifyMachineWebSet(object sender, RoutedEventArgs args) => ClassifyMachine($"web set {SampleMachine} --port=8080");

    private void ClassifyMachine(string command)
    {
        MilaMachineCommandKind? kind = RustNative.TryClassifyMachineCommand(command);
        if (kind is not { } value)
        {
            MachineCommandStatus.Text = $"{command}: unavailable or requires arguments";
            return;
        }
        if (_activeHost is null)
        {
            MachineCommandStatus.Text = $"{command}: {value} — {S("signInFirst", "Sign in first")}";
            return;
        }
        MilaNativeCommandResult formatted = RustNative.TryFormatMachineCommand(command.Split(' ')[0], Guid.Parse(SampleMachine), null);
        MachineCommandStatus.Text = formatted.Status == MilaNativeStatus.Ok
            ? $"{command}: {value} — {S("requestWaiting", "Request formatted by Rust")}" 
            : $"{command}: {S("requestRefused", "Request refused")}";
    }
}
