using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Mila.Windows.Interop;
namespace Mila.Windows;
public sealed partial class MainWindow : Window
{
    public MainWindow() { InitializeComponent(); Navigation.SelectedItem = Navigation.MenuItems[0]; }
    private void OnNavigationChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item) {
            string tag = item.Tag?.ToString() ?? "machines";
            PageTitle.Text = item.Content?.ToString() ?? "Mila";
            PageBody.Text = tag switch { "threads" => "Recent conversations appear here.", "settings" => "Runtime settings are managed by the core library.", _ => "Select a machine to view its status." };
        }
    }
    private void CheckNativeBridge(object sender, RoutedEventArgs args)
    {
        MilaNativeVersionResult result = RustNative.TryGetVersion();
        StatusText.Text = result.Status == MilaNativeStatus.Ok ? "Connected" : "Native runtime unavailable";
    }
}
