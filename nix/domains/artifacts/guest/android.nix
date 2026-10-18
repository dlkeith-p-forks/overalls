{ pkgs, androidSdk }:

let
  sdkRoot = "${androidSdk}/libexec/android-sdk";
  avdName = "overalls-api-36";
  avdRoot = "/var/lib/overalls-android/avd";
in
{ ... }:
{
  # @cc [owner:ghuntley,label:deployment;recovery] android-emulator-software-rendering
  # The Android emulator MUST run inside this Firecracker guest with software
  # rendering and without nested KVM. A future change that removes either flag
  # would make the artifact depend on an unavailable host accelerator.

  # @cc [owner:ghuntley,label:storage;recovery] android-avd-persistent-state
  # The AVD directory MUST be a systemd-managed persistent state directory so a
  # guest restart reuses its device data while image rebuilds retain an immutable
  # SDK and system image closure.

  # @cc [owner:ghuntley,label:security] android-display-loopback-only
  # The guest display bridge MUST bind RFB to loopback. This module does not
  # claim authenticated host display access; no new guest ingress port is opened
  # and an authenticated display relay remains a separate integration.
  environment.systemPackages = [ androidSdk pkgs.xorg.xorgserver pkgs.x11vnc pkgs.socat ];

  users.users.overalls-android = {
    isSystemUser = true;
    group = "overalls-android";
  };
  users.groups.overalls-android = { };

  systemd.services.overalls-android-emulator = {
    description = "Overalls software-rendered Android emulator";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.procps ];
    environment = {
      ANDROID_HOME = sdkRoot;
      ANDROID_SDK_ROOT = sdkRoot;
      ANDROID_USER_HOME = "/var/lib/overalls-android";
      ANDROID_AVD_HOME = avdRoot;
      DISPLAY = ":0";
    };
    serviceConfig = {
      Type = "simple";
      User = "overalls-android";
      Group = "overalls-android";
      StateDirectory = "overalls-android";
      StateDirectoryMode = "0750";
      RuntimeDirectory = "overalls-android";
      RuntimeDirectoryMode = "0750";
      Restart = "always";
      RestartSec = 5;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/overalls-android" "/run/overalls-android" ];
      ExecStart = "${pkgs.writeShellScript "overalls-android-emulator" ''
        set -eu
        mkdir -p "$ANDROID_AVD_HOME"
        if [ ! -f "$ANDROID_AVD_HOME/${avdName}.avd/config.ini" ]; then
          yes "" | ${sdkRoot}/cmdline-tools/latest/bin/avdmanager create avd \
            --force --name ${avdName} \
            --package "system-images;android-36;google_apis;x86_64" \
            --path "$ANDROID_AVD_HOME/${avdName}.avd"
          cat >> "$ANDROID_AVD_HOME/${avdName}.avd/config.ini" <<'CONFIG'
hw.gpu.enabled = yes
hw.gpu.mode = swiftshader_indirect
hw.keyboard = yes
CONFIG
        fi
        ${pkgs.xorg.xorgserver}/bin/Xvfb :0 -screen 0 1080x1920x24 -nolisten tcp \
          -ac -noreset >/run/overalls-android/xvfb.log 2>&1 &
        xvfb_pid=$!
        trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT
        exec ${sdkRoot}/emulator/emulator \
          -avd ${avdName} -no-accel -gpu swiftshader_indirect \
          -no-boot-anim -no-snapshot -ports 5554,5555
      ''}";
    };
  };

  systemd.services.overalls-android-display = {
    description = "Loopback Android emulator display bridge";
    wantedBy = [ "multi-user.target" ];
    requires = [ "overalls-android-emulator.service" ];
    after = [ "overalls-android-emulator.service" ];
    serviceConfig = {
      Type = "simple";
      User = "overalls-android";
      Group = "overalls-android";
      Restart = "always";
      RestartSec = 2;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ExecStart = "${pkgs.writeShellScript "overalls-android-display" ''
        set -eu
        password_file=/run/overalls-android/rfb.pass
        if [ ! -s "$password_file" ]; then
          umask 077
          password=$(head -c 18 /dev/urandom | base64 -w0 | cut -c1-8)
          ${pkgs.x11vnc}/bin/x11vnc -storepasswd "$password" "$password_file" >/dev/null
        fi
        exec ${pkgs.x11vnc}/bin/x11vnc -display :0 -rfbport 5900 -localhost -forever -shared -rfbauth "$password_file" -quiet
      ''}";
    };
  };

  # The only guest-side display transport is a vsock relay to the loopback RFB
  # server. Lilly must still authenticate and authorize the host-side connection;
  # this service does not make RFB public or mint browser authority.
  systemd.services.overalls-android-display-vsock = {
    description = "Android display vsock relay";
    wantedBy = [ "multi-user.target" ];
    requires = [ "overalls-android-display.service" ];
    after = [ "overalls-android-display.service" ];
    serviceConfig = {
      Type = "simple";
      User = "overalls-android";
      Group = "overalls-android";
      Restart = "always";
      RestartSec = 2;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:5900,reuseaddr,fork TCP:127.0.0.1:5900";
    };
  };

}
