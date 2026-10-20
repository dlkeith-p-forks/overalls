#include "mila_platform.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include "device_keys.h"
#include "mila_push.h"
#include "mila_text.h"
#include "owner_only.h"
#include "poke_keys.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableValue* Argument(const EncodableValue* arguments, const char* name) {
  const auto* map = arguments == nullptr ? nullptr : std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return nullptr;
  const auto found = map->find(EncodableValue(name));
  return found == map->end() ? nullptr : &found->second;
}

std::optional<std::string> StringArgument(const EncodableValue* arguments, const char* name) {
  const EncodableValue* value = Argument(arguments, name);
  const auto* text = value == nullptr ? nullptr : std::get_if<std::string>(value);
  if (text == nullptr) return std::nullopt;
  return *text;
}

std::optional<std::string> Host(const EncodableValue* arguments) {
  std::optional<std::string> host = StringArgument(arguments, "host");
  if (!host || !mila_text::ValidHost(*host)) return std::nullopt;
  return host;
}

void Invalid(flutter::MethodResult<EncodableValue>& result, const char* name) {
  result.Error("invalid_argument", name);
}

// Key store failures carry no key material; report only that custody failed.
void Unavailable(flutter::MethodResult<EncodableValue>& result) {
  result.Error("keystore_unavailable");
}

// The URL as text on the clipboard: Windows has no share sheet for a plain
// desktop app, so "share" copies the link and the user pastes it.
bool CopyToClipboard(HWND window, const std::string& url) {
  const std::wstring text = mila_text::Wide(url);
  if (text.empty() || !::OpenClipboard(window)) return false;
  bool copied = false;
  const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
  HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (memory != nullptr) {
    void* target = ::GlobalLock(memory);
    if (target != nullptr) {
      memcpy(target, text.c_str(), bytes);
      ::GlobalUnlock(memory);
      ::EmptyClipboard();
      copied = ::SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
    }
    if (!copied) ::GlobalFree(memory);
  }
  ::CloseClipboard();
  return copied;
}

}  // namespace

MilaPlatform::MilaPlatform(flutter::BinaryMessenger* messenger, HWND window,
                           std::optional<std::string> initial_link)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, kChannel, &flutter::StandardMethodCodec::GetInstance())),
      window_(window),
      initial_link_(std::move(initial_link)),
      alive_(std::make_shared<bool>(true)) {
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call, Result result) {
        Handle(call, std::move(result));
      });
  std::weak_ptr<bool> alive = alive_;
  mila_push::OnLink([this, alive](std::string link) {
    if (alive.expired()) return;
    Post([this, link] { Open(link); });
  });
}

MilaPlatform::~MilaPlatform() {
  *alive_ = false;
  alive_.reset();
  mila_push::OnLink(nullptr);
  channel_->SetMethodCallHandler(nullptr);
}

void MilaPlatform::Post(std::function<void()> task) {
  std::weak_ptr<bool> alive = alive_;
  auto* boxed = new std::function<void()>([alive, task = std::move(task)] {
    if (!alive.expired()) task();
  });
  if (!::PostMessageW(window_, kRunMessage, 0, reinterpret_cast<LPARAM>(boxed))) delete boxed;
}

bool MilaPlatform::HandleRun(UINT message, LPARAM lparam) {
  if (message != kRunMessage) return false;
  std::unique_ptr<std::function<void()>> task(reinterpret_cast<std::function<void()>*>(lparam));
  if (task) (*task)();
  return true;
}

void MilaPlatform::Open(const std::string& link) {
  if (!mila_text::ValidLink(link)) return;
  if (initial_link_taken_) {
    channel_->InvokeMethod("link", std::make_unique<EncodableValue>(link));
  } else {
    // Until Dart asks, the newest link wins, as on darwin.
    initial_link_ = link;
  }
}

void MilaPlatform::RequestToken(Result result) {
  pending_tokens_.push_back(std::move(result));
  if (pending_tokens_.size() > 1) return;  // A request is already running.
  std::weak_ptr<bool> alive = alive_;
  mila_push::RequestChannel([this, alive](std::optional<std::string> token) {
    if (alive.expired()) return;
    Post([this, token] { ReceivedToken(token); });
  });
}

void MilaPlatform::ReceivedToken(std::optional<std::string> token) {
  std::vector<Result> waiting;
  waiting.swap(pending_tokens_);
  const bool changed = token && last_token_ && *last_token_ != *token;
  if (token) last_token_ = token;
  for (Result& result : waiting) {
    // Null means no push here (no App SDK, no package identity, no channel);
    // Dart reports that as push unavailable.
    result->Success(token ? EncodableValue(*token) : EncodableValue());
  }
  if (waiting.empty() && changed) {
    channel_->InvokeMethod("push.tokenChanged", std::make_unique<EncodableValue>(*token));
  }
}

void MilaPlatform::Handle(const flutter::MethodCall<EncodableValue>& call, Result result) {
  const std::string& method = call.method_name();
  const EncodableValue* arguments = call.arguments();
  if (method == "link.initial") {
    result->Success(initial_link_ ? EncodableValue(*initial_link_) : EncodableValue());
    initial_link_.reset();
    initial_link_taken_ = true;
  } else if (method == "pokeKey.public") {
    const std::optional<std::string> host = Host(arguments);
    if (!host) return Invalid(*result, "host");
    const auto key = poke_keys::PublicKey(*host);
    if (!key) return Unavailable(*result);
    result->Success(EncodableValue(std::vector<uint8_t>(key->begin(), key->end())));
  } else if (method == "pokeKey.delete") {
    const std::optional<std::string> host = Host(arguments);
    if (!host) return Invalid(*result, "host");
    poke_keys::Delete(*host);
    result->Success();
  } else if (method == "push.token") {
    RequestToken(std::move(result));
  } else if (method == "push.environment") {
    // WNS has one environment.
    result->Success(EncodableValue("production"));
  } else if (method == "deviceKey.public") {
    const std::optional<std::string> host = Host(arguments);
    if (!host) return Invalid(*result, "host");
    const auto point = device_keys::PublicPoint(*host);
    if (!point) return Unavailable(*result);
    result->Success(EncodableValue(std::vector<uint8_t>(point->begin(), point->end())));
  } else if (method == "deviceKey.sign") {
    const std::optional<std::string> host = Host(arguments);
    if (!host) return Invalid(*result, "host");
    const EncodableValue* data = Argument(arguments, "data");
    const auto* bytes = data == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(data);
    if (bytes == nullptr) return Invalid(*result, "data");
    const auto signature =
        device_keys::Sign(*host, std::vector<unsigned char>(bytes->begin(), bytes->end()));
    if (!signature) return Unavailable(*result);
    result->Success(EncodableValue(std::vector<uint8_t>(signature->begin(), signature->end())));
  } else if (method == "dataDirectory") {
    // Owner-only (user and SYSTEM) by its DACL; Dart re-checks its files.
    const std::optional<std::wstring> path = owner_only::DataDirectory();
    if (!path) return Unavailable(*result);
    result->Success(EncodableValue(mila_text::Utf8(*path)));
  } else if (method == "openUrl") {
    const std::optional<std::string> url = StringArgument(arguments, "url");
    if (!url || !mila_text::ValidHttps(*url)) return Invalid(*result, "url");
    ::ShellExecuteW(nullptr, L"open", mila_text::Wide(*url).c_str(), nullptr, nullptr,
                    SW_SHOWNORMAL);
    result->Success();
  } else if (method == "share") {
    const std::optional<std::string> url = StringArgument(arguments, "url");
    if (!url || !mila_text::ValidHttps(*url)) return Invalid(*result, "url");
    if (!CopyToClipboard(window_, *url)) return Unavailable(*result);
    result->Success();
  } else {
    result->NotImplemented();
  }
}
