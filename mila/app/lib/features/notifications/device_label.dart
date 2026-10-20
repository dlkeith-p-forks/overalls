import 'dart:io';

/// This device's name for the notification device list: the host name the
/// operating system reports, without a `.local` suffix. Null when the system
/// reports only a placeholder, as Android does, or the name cannot be read.
String? localDeviceLabel() {
  final String name;
  try {
    name = Platform.localHostname;
  } on Exception {
    return null;
  }
  return deviceLabelFromHostname(name);
}

/// The label part of [hostname]: null for an empty or placeholder name.
String? deviceLabelFromHostname(String hostname) {
  var name = hostname.trim();
  if (name.toLowerCase().endsWith('.local')) name = name.substring(0, name.length - 6);
  const placeholders = {'', 'localhost', 'localhost.localdomain'};
  return placeholders.contains(name.toLowerCase()) ? null : name;
}
