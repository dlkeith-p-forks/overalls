using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Security.Cryptography;
using Mila.Windows.Interop;
namespace Mila.Windows;
public sealed partial class MainWindow : Window
{
    private string? _activeHost;
    private ushort _deploymentPort = MilaDeployment.DefaultPort;
    private bool _notificationsEnabled;
    private readonly MilaSshKeysController _sshKeys = new(
        _ => Task.FromResult<IReadOnlyList<MilaSshKey>>(Array.Empty<MilaSshKey>()),
        (_, _) => Task.CompletedTask);
    private readonly MilaThreadController _threadController = new();
    private readonly MilaMachineMutationController _machineMutation = new();
    private MilaMachineRow? _selectedMachine;
    private readonly MilaAppLockController _appLock = new(new MilaWindowsHelloBroker());
    private readonly MilaSessionConnection _session = new();
    private bool _closed;
    public MainWindow(string? activation = null)
    {
        InitializeComponent();
        Closed += (_, _) => { _closed = true; _session.Dispose(); };
        ApplyStrings();
        if (MilaDeploymentStore.Load() is { } deployment)
        {
            DeploymentHost.Text = deployment.Host;
            _deploymentPort = deployment.Port;
        }
        Navigation.SelectedItem = Navigation.MenuItems[0];
        if (!string.IsNullOrWhiteSpace(activation)) ApplyActivation(activation);
    }
    private void ApplyActivation(string activation)
    {
        MilaRoute? route = MilaRouteParser.Parse(activation.Trim().Trim('"'));
        if (route is null)
        {
            StatusText.Text = S("invalidRoute", "This link is not a valid Mila route.");
            return;
        }
        _activeHost = route.Value.Host;
        DeploymentHost.Text = route.Value.Host;
        Navigation.SelectedItem = route.Value.Kind switch
        {
            MilaRouteKind.Thread or MilaRouteKind.Threads => Navigation.MenuItems[1],
            MilaRouteKind.Settings => Navigation.MenuItems[2],
            _ => Navigation.MenuItems[0]
        };
        StatusText.Text = route.Value.Kind switch
        {
            MilaRouteKind.Machine => $"{S("routeMachine", "Machine")}: {route.Value.Id?.ToString("D")}",
            MilaRouteKind.Thread => $"{S("routeThread", "Thread")}: {route.Value.Id?.ToString("D")}",
            _ => $"{S("routeOpened", "Opened")}: {route.Value.Path}"
        };
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
        ThreadPrompt.Content = S("threadPrompt", "Prompt"); ThreadAnswer.Content = S("threadAnswer", "Answer");
        ThreadApprove.Content = S("threadPlanApprove", "Approve plan"); ThreadRevise.Content = S("threadPlanRevise", "Revise plan");
        Refresh.Content = S("refresh", "Refresh");
        LockButton.Content = S("lockTitle", "Lock app");
        LockStatus.Text = S("lockUnavailable", "App lock is unavailable until Windows Hello is configured.");
        _ = RefreshLockAvailabilityAsync();
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
    private async void RefreshSshKeys(object sender, RoutedEventArgs args)
    {
        await _sshKeys.LoadAsync(_activeHost is not null);
        SshKeyRows.ItemsSource = _sshKeys.Keys;
        SshKeysStatus.Text = _activeHost is null
            ? S("sshKeysSignInFirst", "Sign in to manage SSH keys.")
            : _sshKeys.Status == MilaSshKeysStatus.Failed
                ? S("sshKeysFailed", "Unable to load SSH keys.")
                : string.Format(S("sshKeysLoaded", "{0} approved keys."), _sshKeys.Keys.Count);
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
        // A browser connection is not an authenticated Rust session yet. Keep
        // mutation controls explicitly signed out until the session broker
        // supplies its non-zero handle.
        _activeHost = null;
        _selectedMachine = null;
        MachineRows.ItemsSource = Array.Empty<MilaMachineRow>();
        _threadController.SetSession(false, null);
        _machineMutation.SetSession(false);
        _session.SignOut();
        _ = ConnectDeploymentAsync(host);
    }
    private async Task ConnectDeploymentAsync(string host)
    {
        try
        {
            byte[]? trust = await new MilaTrustEnrollment(
                MilaTrustStore.HttpsFetch(host), RustNative.TryReconcileTrust)
                .ResolveAsync(host);
            if (trust is null)
            {
                _activeHost = null;
                _session.SignOut();
                StatusText.Text = S("signInApprove", "Approve this device in your browser, then return here.");
                return;
            }

            using DeviceKey deviceKey = DeviceKey.OpenOrCreate(host);
            byte[] publicKey = deviceKey.PublicPoint();
            byte[] trustBytes = trust;
            byte[] publicKeyBytes = publicKey;
            bool connected = await Task.Run(() => _session.Connect(
                trustBytes, host, publicKeyBytes, _deploymentPort, 30_000, bytes => deviceKey.Sign(bytes)));
            if (_closed) return;
            if (!connected || _session.Handle is not { } handle)
            {
                _activeHost = null;
                _machineMutation.SetSession(false);
                StatusText.Text = S("signInFailedUnreachable", "Unable to connect to deployment.");
                return;
            }

            _activeHost = host;
            MilaDeploymentStore.Save(new MilaDeployment(host, _deploymentPort));
            _machineMutation.SetSession(true, handle);
            StatusText.Text = S("connected", MilaStrings.Connected);
            RefreshMachines();
        }
        catch (ArgumentException)
        {
            _activeHost = null;
            _session.SignOut();
            if (!_closed) StatusText.Text = S("invalidHost", "Enter a valid deployment host.");
        }
        catch (Exception error) when (error is CryptographicException or IOException or UnauthorizedAccessException)
        {
            _activeHost = null;
            _session.SignOut();
            _machineMutation.SetSession(false);
            if (!_closed) StatusText.Text = S("signInFailedUnreachable", "Unable to connect to deployment.");
        }
        finally
        {
            if (!_closed) ConnectDeployment.IsEnabled = true;
        }
    }
    private async Task RefreshLockAvailabilityAsync()
    {
        await _appLock.RefreshAvailabilityAsync();
        if (_appLock.State == MilaAppLockState.Unavailable)
            LockStatus.Text = S("lockUnavailable", "App lock is unavailable until Windows Hello is configured.");
    }
    private void LockApp(object sender, RoutedEventArgs args)
    {
        _appLock.Lock();
        if (!_appLock.IsLocked) return;
        Navigation.IsHitTestVisible = false;
        LockButton.Content = S("unlock", "Unlock");
        LockStatus.Text = S("lockedTitle", "Mila is locked") + " — " + S("lockReason", "Unlock Mila");
        LockButton.Click -= LockApp;
        LockButton.Click += UnlockApp;
    }
    private async void UnlockApp(object sender, RoutedEventArgs args)
    {
        LockButton.IsEnabled = false;
        bool unlocked = await _appLock.UnlockAsync();
        LockButton.IsEnabled = true;
        if (!unlocked)
        {
            LockStatus.Text = S("lockReason", "Unlock Mila");
            return;
        }
        Navigation.IsHitTestVisible = true;
        LockButton.Content = S("lockTitle", "Lock app");
        LockStatus.Text = S("ready", "Ready");
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
            if (tag == "threads") RefreshThreads();
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
        _selectedMachine = null;
        _machineMutation.SetSession(_session.Handle is { } handle, _session.Handle ?? 0);
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
        _selectedMachine = machine;
        string access = machine.CanManage ? S("machineAccessOwner", "Manage") : machine.CanWrite ? S("machineAccessShared", "Write") : S("terminalReadOnly", "Read only");
        MachineCommandStatus.Text = $"{machine.Name} ({machine.DesiredState}) — {access}";
    }

    private void RefreshThreads()
    {
        if (_activeHost is null)
        {
            _threadController.SetSession(false, null);
            ThreadRows.ItemsSource = Array.Empty<MilaThreadRow>();
            ThreadDetail.Text = S("signInFirst", "Sign in first");
            return;
        }
        // The Rust session supplies this bounded envelope when connected. Keep an empty
        // typed listing until that envelope arrives; no unvalidated JSON enters the UI.
        MilaThreadListing listing = new(Array.Empty<MilaThreadRow>(), false);
        _threadController.SetSession(true, listing);
        ThreadRows.ItemsSource = listing.Threads;
        ThreadDetail.Text = S("threadsEmpty", "No threads");
    }

    private void OnThreadSelected(object sender, SelectionChangedEventArgs args)
    {
        if (ThreadRows.SelectedItem is not MilaThreadRow thread || !_threadController.Select(thread.Id)) return;
        ThreadDetail.Text = $"{thread.Title} ({thread.State})";
        ThreadCommandStatus.Text = S("threadReady", "Thread selected");
    }
    private void SubmitThreadPrompt(object sender, RoutedEventArgs args) => SubmitThread(MilaThreadAction.Prompt);
    private void SubmitThreadAnswer(object sender, RoutedEventArgs args) => SubmitThread(MilaThreadAction.Answer);
    private void SubmitThreadApprove(object sender, RoutedEventArgs args) => SubmitThread(MilaThreadAction.PlanApprove);
    private void SubmitThreadRevise(object sender, RoutedEventArgs args) => SubmitThread(MilaThreadAction.PlanRevise);
    private void SubmitThread(MilaThreadAction action)
    {
        bool applied = _threadController.Submit(action);
        ThreadCommandStatus.Text = applied ? S("requestSucceeded", "Request submitted") : S("requestFailed", "Request refused");
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
    private void ClassifyMachineStart(object sender, RoutedEventArgs args) => SubmitMachineMutation("start");
    private void ClassifyMachineStop(object sender, RoutedEventArgs args) => SubmitMachineMutation("stop");
    private void ClassifyMachinePause(object sender, RoutedEventArgs args) => SubmitMachineMutation("pause");
    private void ClassifyMachineResume(object sender, RoutedEventArgs args) => SubmitMachineMutation("resume");
    private void ClassifyMachineDelete(object sender, RoutedEventArgs args) => SubmitMachineMutation("rm");
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

    private void SubmitMachineMutation(string action)
    {
        if (_selectedMachine is null)
        {
            MachineCommandStatus.Text = S("machineNotSelected", "Select a machine first.");
            return;
        }
        bool applied = _machineMutation.Submit(
            _selectedMachine.Id,
            action,
            Guid.NewGuid().ToString("D"));
        MachineCommandStatus.Text = applied
            ? S("requestSucceeded", "Request submitted")
            : _machineMutation.State.Kind == MilaMachineMutationStateKind.SignedOut
                ? S("signInFirst", "Sign in first")
                : S("requestFailed", "Request refused");
    }
}
