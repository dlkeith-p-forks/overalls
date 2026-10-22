namespace Mila.Windows.Interop;

internal enum MilaWindowsNotificationState { Disabled, Registered, Unavailable, Invalid }

/// <summary>
/// Owns the Windows notification capability without retaining the WNS bearer URI.
/// The native runner obtains the channel; this controller only validates its metadata.
/// </summary>
internal sealed class MilaWindowsNotificationController
{
    private readonly Func<string, string, string, MilaNativeStatus> _validate;
    internal MilaWindowsNotificationState State { get; private set; } = MilaWindowsNotificationState.Disabled;

    internal MilaWindowsNotificationController(
        Func<string, string, string, MilaNativeStatus>? validate = null)
    {
        _validate = validate ?? RustNative.TryValidateWindowsPushRegistration;
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:security] mila-windows-push-registration
    /// WNS channel URIs MUST be validated by Rust and MUST NOT be retained by the
    /// managed shell; failed validation MUST leave notifications disabled.
    /// </summary>
    internal MilaWindowsNotificationState Register(
        string channelUri, string appId, string deployment)
    {
        MilaNativeStatus status = _validate(channelUri, appId, deployment);
        State = status switch
        {
            MilaNativeStatus.Ok => MilaWindowsNotificationState.Registered,
            MilaNativeStatus.Unavailable => MilaWindowsNotificationState.Unavailable,
            _ => MilaWindowsNotificationState.Invalid,
        };
        return State;
    }

    internal void Disable() => State = MilaWindowsNotificationState.Disabled;
}
