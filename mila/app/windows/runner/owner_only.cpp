#include "owner_only.h"

// clang-format off
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>
// clang-format on

#include <memory>

namespace owner_only {
namespace {

struct LocalFreeDeleter {
  void operator()(void* p) const { ::LocalFree(p); }
};

// The current user's SID as a string, e.g. `S-1-5-21-...`.
std::optional<std::wstring> UserSid() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) return std::nullopt;
  DWORD size = 0;
  ::GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<unsigned char> buffer(size);
  std::optional<std::wstring> result;
  if (size > 0 && ::GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
    wchar_t* text = nullptr;
    if (::ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &text)) {
      result = std::wstring(text);
      ::LocalFree(text);
    }
  }
  ::CloseHandle(token);
  return result;
}

// `D:P(A;OICI;FA;;;USER)(A;OICI;FA;;;SY)` for a directory and the same
// without inheritance flags for a file, as `ownerOnlySddl` in Dart.
std::optional<std::wstring> Sddl(bool directory) {
  const std::optional<std::wstring> user = UserSid();
  if (!user) return std::nullopt;
  const std::wstring flags = directory ? L"OICI" : L"";
  return L"D:P(A;" + flags + L";FA;;;" + *user + L")(A;" + flags + L";FA;;;SY)";
}

using Descriptor = std::unique_ptr<void, LocalFreeDeleter>;

Descriptor OwnerOnlyDescriptor(bool directory) {
  const std::optional<std::wstring> sddl = Sddl(directory);
  if (!sddl) return nullptr;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl->c_str(), SDDL_REVISION_1,
                                                              &descriptor, nullptr)) {
    return nullptr;
  }
  return Descriptor(descriptor);
}

bool Protect(const std::wstring& path, bool directory) {
  Descriptor descriptor = OwnerOnlyDescriptor(directory);
  if (!descriptor) return false;
  BOOL present = FALSE;
  BOOL defaulted = FALSE;
  PACL dacl = nullptr;
  if (!::GetSecurityDescriptorDacl(descriptor.get(), &present, &dacl, &defaulted) || !present) {
    return false;
  }
  return ::SetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
                                 DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                 nullptr, nullptr, dacl, nullptr) == ERROR_SUCCESS;
}

// Whether [path]'s DACL is protected and grants only the user and SYSTEM.
bool IsOwnerOnly(const std::wstring& path) {
  PSECURITY_DESCRIPTOR raw = nullptr;
  if (::GetNamedSecurityInfoW(path.c_str(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr,
                              nullptr, nullptr, nullptr, &raw) != ERROR_SUCCESS) {
    return false;
  }
  Descriptor descriptor(raw);
  wchar_t* text = nullptr;
  if (!::ConvertSecurityDescriptorToStringSecurityDescriptorW(
          descriptor.get(), SDDL_REVISION_1, DACL_SECURITY_INFORMATION, &text, nullptr)) {
    return false;
  }
  const std::wstring sddl(text);
  ::LocalFree(text);
  const std::optional<std::wstring> user = UserSid();
  if (!user || sddl.rfind(L"D:", 0) != 0) return false;
  const size_t first = sddl.find(L'(');
  if (sddl.substr(2, first == std::wstring::npos ? std::wstring::npos : first - 2).find(L'P') ==
      std::wstring::npos) {
    return false;
  }
  // As `sddlIsOwnerOnly` in Dart: past the DACL flags (which must include
  // `P`), deny entries are harmless and every other ACE must name the user
  // or SYSTEM.
  size_t position = 3;
  while (position < sddl.size() && sddl[position] >= L'A' && sddl[position] <= L'Z') ++position;
  while (position < sddl.size()) {
    if (sddl[position] != L'(') return false;
    const size_t close = sddl.find(L')', position);
    if (close == std::wstring::npos) return false;
    const std::wstring ace = sddl.substr(position + 1, close - position - 1);
    std::vector<std::wstring> fields;
    size_t from = 0;
    while (true) {
      const size_t semicolon = ace.find(L';', from);
      fields.push_back(ace.substr(from, semicolon == std::wstring::npos ? std::wstring::npos
                                                                        : semicolon - from));
      if (semicolon == std::wstring::npos) break;
      from = semicolon + 1;
    }
    if (fields.size() < 6) return false;
    const bool deny = fields[0] == L"D" || fields[0] == L"OD";
    if (!deny && fields[5] != *user && fields[5] != L"SY") return false;
    position = close + 1;
  }
  return true;
}

}  // namespace

std::optional<std::wstring> DataDirectory() {
  PWSTR base = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &base))) {
    return std::nullopt;
  }
  std::wstring path = std::wstring(base) + L"\\dev.overalls.mila";
  ::CoTaskMemFree(base);
  if (!EnsureDirectory(path)) return std::nullopt;
  return path;
}

bool EnsureDirectory(const std::wstring& path) {
  Descriptor descriptor = OwnerOnlyDescriptor(true);
  if (!descriptor) return false;
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor.get(), FALSE};
  if (::CreateDirectoryW(path.c_str(), &attributes)) return true;
  if (::GetLastError() != ERROR_ALREADY_EXISTS) return false;
  const DWORD kind = ::GetFileAttributesW(path.c_str());
  if (kind == INVALID_FILE_ATTRIBUTES || !(kind & FILE_ATTRIBUTE_DIRECTORY) ||
      (kind & FILE_ATTRIBUTE_REPARSE_POINT)) {
    return false;
  }
  return IsOwnerOnly(path) || Protect(path, true);
}

bool WriteFile(const std::wstring& path, const std::vector<unsigned char>& bytes) {
  Descriptor descriptor = OwnerOnlyDescriptor(false);
  if (!descriptor) return false;
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor.get(), FALSE};
  const std::wstring temporary = path + L".tmp";
  HANDLE file = ::CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, &attributes, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const BOOL ok = ::WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written,
                              nullptr) &&
                  written == bytes.size() && ::FlushFileBuffers(file);
  ::CloseHandle(file);
  // CREATE_ALWAYS keeps an existing file's DACL; protect it explicitly.
  if (!ok || !Protect(temporary, false) ||
      !::MoveFileExW(temporary.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    ::DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

std::optional<std::vector<unsigned char>> ReadFile(const std::wstring& path, size_t limit) {
  if (!IsOwnerOnly(path)) return std::nullopt;
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return std::nullopt;
  LARGE_INTEGER size{};
  std::optional<std::vector<unsigned char>> result;
  if (::GetFileSizeEx(file, &size) && size.QuadPart >= 0 &&
      static_cast<unsigned long long>(size.QuadPart) <= limit) {
    std::vector<unsigned char> bytes(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    if (bytes.empty() ||
        (::ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr) &&
         read == bytes.size())) {
      result = std::move(bytes);
    }
  }
  ::CloseHandle(file);
  return result;
}

}  // namespace owner_only
