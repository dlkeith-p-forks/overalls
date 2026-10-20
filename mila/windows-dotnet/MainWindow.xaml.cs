using Microsoft.UI.Xaml;
using Mila.Windows.Interop;

namespace Mila.Windows;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }

    private void CheckNativeBridge(object sender, RoutedEventArgs args)
    {
        MilaNativeVersionResult result = RustNative.TryGetVersion();
        StatusText.Text = result.Status == MilaNativeStatus.Ok ? "Connected" : "Native runtime unavailable";
    }
}
