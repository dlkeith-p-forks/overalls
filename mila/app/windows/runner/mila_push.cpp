#include "mila_push.h"

#if defined(MILA_WINDOWS_APP_SDK)

// clang-format off
#include <windows.h>
#include <appmodel.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.ApplicationModel.Activation.h>
#include <winrt/Microsoft.Windows.AppLifecycle.h>
#include <winrt/Microsoft.Windows.AppNotifications.h>
#include <winrt/Microsoft.Windows.AppNotifications.Builder.h>
#include <winrt/Microsoft.Windows.PushNotifications.h>
// clang-format on

#include <algorithm>
#include <mutex>
#include <variant>

#include "mila/poke_opener.h"
#include "mila_text.h"
#include "notification_text.h"
#include "poke_keys.h"

namespace mila_push {
namespace {

namespace lifecycle = winrt::Microsoft::Windows::AppLifecycle;
namespace notifications = winrt::Microsoft::Windows::AppNotifications;
namespace builder = winrt::Microsoft::Windows::AppNotifications::Builder;
namespace push = winrt::Microsoft::Windows::PushNotifications;

std::mutex lock;
std::function<void(std::string)> link_handler;
std::optional<std::string> pending_link;
bool registered = false;

bool HasPackageIdentity() {
  UINT32 length = 0;
  return ::GetCurrentPackageFullName(&length, nullptr) != APPMODEL_ERROR_NO_PACKAGE;
}

std::optional<std::string> LinkFrom(const notifications::AppNotificationActivatedEventArgs& args) {
  const auto arguments = args.Arguments();
  if (!arguments.HasKey(L"link")) return std::nullopt;
  const std::string link = winrt::to_string(arguments.Lookup(L"link"));
  if (!mila_text::ValidLink(link)) return std::nullopt;
  return link;
}

void Deliver(std::string link) {
  std::function<void(std::string)> handler;
  {
    std::lock_guard<std::mutex> guard(lock);
    if (!link_handler) {
      pending_link = std::move(link);
      return;
    }
    handler = link_handler;
  }
  handler(std::move(link));
}

// Opens a raw WNS body against every stored poke key and shows the fixed
// text with the decrypted route's link. Anything that does not open shows
// nothing, as on Android: a raw push has no alert to fall back to.
void ShowPoke(const winrt::com_array<uint8_t>& payload) {
  const std::string body(payload.begin(), payload.end());
  const std::optional<std::string> poke = mila::poke::FromWnsPayload(body);
  if (!poke) return;
  for (auto& [host, key] : poke_keys::All()) {
    mila::poke::PrivateKey private_key{};
    std::copy(key.begin(), key.end(), private_key.begin());
    const mila::poke::Result result = mila::poke::Open(*poke, host, private_key);
    ::SecureZeroMemory(private_key.data(), private_key.size());
    ::SecureZeroMemory(key.data(), key.size());
    const auto* opened = std::get_if<mila::poke::Poke>(&result);
    if (opened == nullptr) continue;
    const std::string link = "overalls://" + host + opened->route;
    if (!mila_text::ValidLink(link)) return;
    const notification_text::Text text = notification_text::ForUser();
    const auto notification = builder::AppNotificationBuilder()
                                  .AddArgument(L"link", winrt::to_hstring(link))
                                  .AddText(winrt::hstring(text.title))
                                  .AddText(winrt::hstring(text.body))
                                  .BuildNotification();
    notifications::AppNotificationManager::Default().Show(notification);
    return;
  }
}

}  // namespace

Launch Start(std::optional<std::string>& link) {
  if (!HasPackageIdentity()) return Launch::kContinue;
  try {
    auto manager = notifications::AppNotificationManager::Default();
    manager.NotificationInvoked([](const auto&, const notifications::AppNotificationActivatedEventArgs& args) {
      if (auto clicked = LinkFrom(args)) Deliver(std::move(*clicked));
    });
    manager.Register();
    if (push::PushNotificationManager::IsSupported()) {
      auto pushes = push::PushNotificationManager::Default();
      // Foreground pokes: the running instance opens them itself.
      pushes.PushReceived([](const auto&, const push::PushNotificationReceivedEventArgs& args) {
        ShowPoke(args.Payload());
      });
      pushes.Register();
    }
    registered = true;

    const auto activation = lifecycle::AppInstance::GetCurrent().GetActivatedEventArgs();
    switch (activation.Kind()) {
      case lifecycle::ExtendedActivationKind::Push: {
        const auto args = activation.Data().as<push::PushNotificationReceivedEventArgs>();
        const auto deferral = args.GetDeferral();
        ShowPoke(args.Payload());
        deferral.Complete();
        return Launch::kExit;
      }
      case lifecycle::ExtendedActivationKind::AppNotification: {
        const auto args = activation.Data().as<notifications::AppNotificationActivatedEventArgs>();
        if (auto clicked = LinkFrom(args)) link = std::move(clicked);
        break;
      }
      case lifecycle::ExtendedActivationKind::Protocol: {
        const auto args =
            activation.Data().as<winrt::Windows::ApplicationModel::Activation::IProtocolActivatedEventArgs>();
        const std::string uri = winrt::to_string(args.Uri().AbsoluteUri());
        if (mila_text::ValidLink(uri)) link = uri;
        break;
      }
      default:
        break;
    }
  } catch (const winrt::hresult_error&) {
    // No App SDK runtime or no registration: push stays unavailable.
    registered = false;
  }
  return Launch::kContinue;
}

bool Available() {
  if (!registered) return false;
  try {
    return push::PushNotificationManager::IsSupported();
  } catch (const winrt::hresult_error&) {
    return false;
  }
}

void RequestChannel(std::function<void(std::optional<std::string>)> done) {
  if (!Available()) return done(std::nullopt);
  try {
    const winrt::guid remote_id(MILA_WNS_REMOTE_ID);
    auto operation = push::PushNotificationManager::Default().CreateChannelAsync(remote_id);
    operation.Completed([done](const auto& completed, winrt::Windows::Foundation::AsyncStatus status) {
      std::optional<std::string> uri;
      try {
        if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
          const auto result = completed.GetResults();
          if (result.Status() == push::PushNotificationChannelStatus::CompletedSuccess) {
            uri = winrt::to_string(result.Channel().Uri().AbsoluteUri());
          }
        }
      } catch (const winrt::hresult_error&) {
        uri.reset();
      }
      done(uri);
    });
  } catch (const winrt::hresult_error&) {
    done(std::nullopt);
  }
}

void OnLink(std::function<void(std::string)> on_link) {
  std::optional<std::string> waiting;
  {
    std::lock_guard<std::mutex> guard(lock);
    link_handler = on_link;
    waiting.swap(pending_link);
  }
  if (waiting && on_link) on_link(std::move(*waiting));
}

void Stop() {
  if (!registered) return;
  try {
    notifications::AppNotificationManager::Default().Unregister();
  } catch (const winrt::hresult_error&) {
  }
}

}  // namespace mila_push

#else  // !MILA_WINDOWS_APP_SDK

namespace mila_push {

Launch Start(std::optional<std::string>&) { return Launch::kContinue; }
bool Available() { return false; }
void RequestChannel(std::function<void(std::optional<std::string>)> done) { done(std::nullopt); }
void OnLink(std::function<void(std::string)>) {}
void Stop() {}

}  // namespace mila_push

#endif
