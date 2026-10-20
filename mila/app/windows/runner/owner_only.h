#ifndef RUNNER_OWNER_ONLY_H_
#define RUNNER_OWNER_ONLY_H_

#include <optional>
#include <string>
#include <vector>

// @cc [owner:ghuntley,label:security] mila-owner-only-dacl
// Mila's directories and files on Windows MUST carry a protected DACL that
// grants only the current user and SYSTEM, exactly as
// `owner_only_windows.dart` writes and checks it. A file whose DACL grants
// anyone else MUST NOT be read.
namespace owner_only {

// `%LOCALAPPDATA%\dev.overalls.mila`, created owner-only, or nothing.
std::optional<std::wstring> DataDirectory();

// [path] (a directory under DataDirectory) created or re-protected
// owner-only.
bool EnsureDirectory(const std::wstring& path);

// Replaces [path] atomically with [bytes], owner-only.
bool WriteFile(const std::wstring& path, const std::vector<unsigned char>& bytes);

// The contents of [path] if its DACL is still owner-only; at most [limit].
std::optional<std::vector<unsigned char>> ReadFile(const std::wstring& path, size_t limit);

}  // namespace owner_only

#endif  // RUNNER_OWNER_ONLY_H_
