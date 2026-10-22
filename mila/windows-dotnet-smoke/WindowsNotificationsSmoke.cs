using Mila.Windows.Interop;

internal static class WindowsNotificationsSmoke
{
    internal static void Run()
    {
        MilaWindowsNotificationController controller = new((channel, app, host) =>
            channel == "https://push.notify.windows.com/channel/abc" &&
            app == "dev.overalls.mila" && host == "mgmt.example.test"
                ? MilaNativeStatus.Ok
                : MilaNativeStatus.InvalidRequest);
        Program.Require(
            controller.Register("https://push.notify.windows.com/channel/abc", "dev.overalls.mila", "mgmt.example.test") ==
            MilaWindowsNotificationState.Registered, "WNS metadata registration");
        Program.Require(controller.Register("https://evil.example/channel", "dev.overalls.mila", "mgmt.example.test") ==
            MilaWindowsNotificationState.Invalid, "foreign WNS channel refusal");
        controller.Disable();
        Program.Require(controller.State == MilaWindowsNotificationState.Disabled, "notification disable");
    }
}
