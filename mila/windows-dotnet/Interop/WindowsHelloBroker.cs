#if WINDOWS
using System.Threading;
using System.Threading.Tasks;
using Windows.Security.Credentials.UI;

namespace Mila.Windows.Interop;

/// Windows Hello adapter. The managed UI receives only availability and outcome.
public sealed class MilaWindowsHelloBroker : IMilaWindowsHelloVerifier
{
    public async Task<MilaWindowsHelloAvailability> CheckAvailabilityAsync(CancellationToken cancellationToken = default)
    {
        UserConsentVerifierAvailability availability = await UserConsentVerifier.CheckAvailabilityAsync().AsTask(cancellationToken);
        return availability == UserConsentVerifierAvailability.Available
            ? MilaWindowsHelloAvailability.Available
            : MilaWindowsHelloAvailability.Unavailable;
    }

    public async Task<MilaWindowsHelloVerification> VerifyAsync(string message, CancellationToken cancellationToken = default)
    {
        UserConsentVerificationResult result = await UserConsentVerifier.RequestVerificationAsync(message).AsTask(cancellationToken);
        return result == UserConsentVerificationResult.Verified
            ? MilaWindowsHelloVerification.Verified
            : result is UserConsentVerificationResult.DeviceNotPresent or UserConsentVerificationResult.NotConfiguredForUser or UserConsentVerificationResult.DisabledByPolicy
                ? MilaWindowsHelloVerification.Unavailable
                : MilaWindowsHelloVerification.Rejected;
    }
}
#endif
