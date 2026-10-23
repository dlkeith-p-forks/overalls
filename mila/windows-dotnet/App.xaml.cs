using Microsoft.UI.Xaml;

namespace Mila.Windows;

public partial class App : Application
{
    private Window? _window;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (_window is MainWindow existing)
        {
            existing.HandleExternalActivation(args.Arguments);
        }
        else
        {
            _window = new MainWindow(args.Arguments);
        }
        _window.Activate();
    }
}
