using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Mila.Windows.Interop;
namespace Mila.Windows;
public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        ApplyStrings();
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
        MachineCommandsTitle.Text = S("machineMore", "Machine commands");
        MachineCommandsHelp.Text = S("machineAccess", "Commands are classified by the Rust core before execution.");
        MachineList.Content = S("tabInfo", "List"); MachineShow.Content = S("machineLoading", "Show");
        MachineNew.Content = S("actionNew", "New"); MachineResize.Content = S("actionResize", "Resize");
        MachineStart.Content = S("actionStart", "Start"); MachineStop.Content = S("actionStop", "Stop");
        MachinePause.Content = S("actionPause", "Pause"); MachineResume.Content = S("actionResume", "Resume");
        MachineDelete.Content = S("actionDelete", "Delete"); MachineShareAdd.Content = S("sharingAdd", "Share add");
        MachineShareRemove.Content = S("sharingRemove", "Share remove"); MachineWebShow.Content = S("webOpen", "Web show");
        MachineWebSet.Content = S("webSave", "Web set");
        ThreadCommandsTitle.Text = S("tabThreads", "Thread commands");
        ThreadCommandsHelp.Text = S("threadWorking", "Commands are validated by the Rust core before execution.");
        ThreadList.Content = S("tabInfo", "List"); ThreadShow.Content = S("machineLoading", "Show");
        ThreadTurns.Content = S("threadEventTurnStarted", "Turns"); ThreadRead.Content = S("threadEventOther", "Read");
        Refresh.Content = S("refresh", "Refresh");
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
        MachineRows.ItemsSource = Array.Empty<MilaMachineRow>();
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
        MachineCommandStatus.Text = kind is { } value
            ? $"{command}: {value} (Rust)"
            : $"{command}: unavailable or requires arguments";
    }
}
