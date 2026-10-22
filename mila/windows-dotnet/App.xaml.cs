using Microsoft.UI.Xaml;

namespace Mila.Windows;

public partial class App : Application
{
    private Window? _window;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window ??= new MainWindow(args.Arguments);
        _window.Activate();
    }
}
