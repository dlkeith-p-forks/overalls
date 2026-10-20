// Owner-only files on Windows, where there are no permission bits: a
// protected DACL granting only the current user and SYSTEM, applied before
// any byte is written and checked before any byte is read.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

const int _seFileObject = 1;
const int _daclSecurityInformation = 0x4;
const int _protectedDaclSecurityInformation = 0x80000000;
const int _sddlRevision1 = 1;
const int _tokenQuery = 0x0008;
const int _tokenUser = 1;

typedef _OpenProcessTokenC = Int32 Function(IntPtr, Uint32, Pointer<IntPtr>);
typedef _OpenProcessToken = int Function(int, int, Pointer<IntPtr>);
typedef _GetCurrentProcessC = IntPtr Function();
typedef _GetCurrentProcess = int Function();
typedef _GetTokenInformationC =
    Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>);
typedef _GetTokenInformation = int Function(int, int, Pointer<Void>, int, Pointer<Uint32>);
typedef _ConvertSidToStringSidC = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>);
typedef _ConvertSidToStringSid = int Function(Pointer<Void>, Pointer<Pointer<Utf16>>);
typedef _StringToDescriptorC =
    Int32 Function(Pointer<Utf16>, Uint32, Pointer<Pointer<Void>>, Pointer<Uint32>);
typedef _StringToDescriptor =
    int Function(Pointer<Utf16>, int, Pointer<Pointer<Void>>, Pointer<Uint32>);
typedef _DescriptorToStringC =
    Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<Pointer<Utf16>>, Pointer<Uint32>);
typedef _DescriptorToString =
    int Function(Pointer<Void>, int, int, Pointer<Pointer<Utf16>>, Pointer<Uint32>);
typedef _GetDaclC =
    Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, Pointer<Int32>);
typedef _GetDacl =
    int Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, Pointer<Int32>);
typedef _SetNamedSecurityInfoC =
    Uint32 Function(
      Pointer<Utf16>,
      Int32,
      Uint32,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
    );
typedef _SetNamedSecurityInfo =
    int Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
    );
typedef _GetNamedSecurityInfoC =
    Uint32 Function(
      Pointer<Utf16>,
      Int32,
      Uint32,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
    );
typedef _GetNamedSecurityInfo =
    int Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
    );
typedef _HandleC = IntPtr Function(IntPtr);
typedef _Handle = int Function(int);
typedef _LocalFreeC = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFree = Pointer<Void> Function(Pointer<Void>);

final DynamicLibrary _advapi = DynamicLibrary.open('advapi32.dll');
final DynamicLibrary _kernel = DynamicLibrary.open('kernel32.dll');

final _localFree = _kernel.lookupFunction<_LocalFreeC, _LocalFree>('LocalFree');

/// The current user's SID in string form, read once from the process token.
final String currentUserSid = () {
  final openToken = _advapi.lookupFunction<_OpenProcessTokenC, _OpenProcessToken>(
    'OpenProcessToken',
  );
  final process = _kernel.lookupFunction<_GetCurrentProcessC, _GetCurrentProcess>(
    'GetCurrentProcess',
  );
  final info = _advapi.lookupFunction<_GetTokenInformationC, _GetTokenInformation>(
    'GetTokenInformation',
  );
  final toString = _advapi.lookupFunction<_ConvertSidToStringSidC, _ConvertSidToStringSid>(
    'ConvertSidToStringSidW',
  );
  final close = _kernel.lookupFunction<_HandleC, _Handle>('CloseHandle');
  return using((arena) {
    final token = arena<IntPtr>();
    if (openToken(process(), _tokenQuery, token) == 0) throw StateError('OpenProcessToken failed');
    try {
      final length = arena<Uint32>();
      info(token.value, _tokenUser, nullptr, 0, length);
      final buffer = arena<Uint8>(length.value);
      if (info(token.value, _tokenUser, buffer.cast(), length.value, length) == 0) {
        throw StateError('GetTokenInformation failed');
      }
      // TOKEN_USER starts with SID_AND_ATTRIBUTES, whose first field is the SID.
      final sid = buffer.cast<Pointer<Void>>().value;
      final text = arena<Pointer<Utf16>>();
      if (toString(sid, text) == 0) throw StateError('ConvertSidToStringSid failed');
      try {
        return text.value.toDartString();
      } finally {
        _localFree(text.value.cast());
      }
    } finally {
      close(token.value);
    }
  });
}();

/// The protected DACL for an owner-only directory (inherited by its files)
/// or file: full access for [user] and SYSTEM, nothing for anyone else.
String ownerOnlySddl(String user, {required bool directory}) {
  final flags = directory ? 'OICI' : '';
  return 'D:P(A;$flags;FA;;;$user)(A;$flags;FA;;;SY)';
}

// @cc [owner:ghuntley,label:security] mila-owner-only-dacl
// On Windows an owner-only file's DACL MUST be protected (no inherited
// entries) and MUST allow access to no SID but the current user and SYSTEM.
// Deny entries are harmless and accepted; anything else is refused.
/// Whether an SDDL DACL is owner-only for [user].
bool sddlIsOwnerOnly(String sddl, String user) {
  final match = RegExp(r'^D:([A-Z]*)((?:\([^()]*\))*)$').firstMatch(sddl);
  if (match == null || !match.group(1)!.contains('P')) return false;
  final aces = RegExp(r'\(([^()]*)\)').allMatches(match.group(2)!).map((m) => m.group(1)!);
  for (final ace in aces) {
    final fields = ace.split(';');
    if (fields.length < 6) return false;
    final type = fields[0];
    final sid = fields[5];
    if (type == 'D' || type == 'OD') continue;
    if (sid != user && sid != 'SY') return false;
  }
  return true;
}

/// Applies the owner-only DACL to [path].
void protectPath(String path, {required bool directory}) {
  final fromString = _advapi.lookupFunction<_StringToDescriptorC, _StringToDescriptor>(
    'ConvertStringSecurityDescriptorToSecurityDescriptorW',
  );
  final getDacl = _advapi.lookupFunction<_GetDaclC, _GetDacl>('GetSecurityDescriptorDacl');
  final setInfo = _advapi.lookupFunction<_SetNamedSecurityInfoC, _SetNamedSecurityInfo>(
    'SetNamedSecurityInfoW',
  );
  using((arena) {
    final descriptor = arena<Pointer<Void>>();
    final sddl = ownerOnlySddl(
      currentUserSid,
      directory: directory,
    ).toNativeUtf16(allocator: arena);
    if (fromString(sddl, _sddlRevision1, descriptor, nullptr) == 0) {
      throw StateError('owner-only SDDL rejected');
    }
    try {
      final present = arena<Int32>();
      final dacl = arena<Pointer<Void>>();
      final defaulted = arena<Int32>();
      if (getDacl(descriptor.value, present, dacl, defaulted) == 0 || present.value == 0) {
        throw StateError('owner-only descriptor has no DACL');
      }
      final status = setInfo(
        path.toNativeUtf16(allocator: arena),
        _seFileObject,
        _daclSecurityInformation | _protectedDaclSecurityInformation,
        nullptr,
        nullptr,
        dacl.value,
        nullptr,
      );
      if (status != 0) throw StateError('SetNamedSecurityInfo failed: $status');
    } finally {
      _localFree(descriptor.value);
    }
  });
}

/// Whether [path]'s DACL is owner-only for the current user.
bool pathIsOwnerOnly(String path) {
  final getInfo = _advapi.lookupFunction<_GetNamedSecurityInfoC, _GetNamedSecurityInfo>(
    'GetNamedSecurityInfoW',
  );
  final toString = _advapi.lookupFunction<_DescriptorToStringC, _DescriptorToString>(
    'ConvertSecurityDescriptorToStringSecurityDescriptorW',
  );
  return using((arena) {
    final descriptor = arena<Pointer<Void>>();
    final status = getInfo(
      path.toNativeUtf16(allocator: arena),
      _seFileObject,
      _daclSecurityInformation,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      descriptor,
    );
    if (status != 0) return false;
    try {
      final text = arena<Pointer<Utf16>>();
      if (toString(descriptor.value, _sddlRevision1, _daclSecurityInformation, text, nullptr) ==
          0) {
        return false;
      }
      try {
        return sddlIsOwnerOnly(text.value.toDartString(), currentUserSid);
      } finally {
        _localFree(text.value.cast());
      }
    } finally {
      _localFree(descriptor.value);
    }
  });
}
