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
  # The RFB server MUST bind loopback. A typed relay owns the fixed TAP ingress
  # port and accepts only Lilly's bounded display preface before proxying RFB.
  environment.systemPackages = [ androidSdk pkgs.gawk pkgs.jdk pkgs.python3 pkgs.xorg.xorgserver pkgs.x11vnc ];

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
    path = [ pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gawk pkgs.gnugrep pkgs.procps ];
    environment = {
      ANDROID_HOME = sdkRoot;
      ANDROID_SDK_ROOT = sdkRoot;
      ANDROID_USER_HOME = "/var/lib/overalls-android";
      ANDROID_AVD_HOME = avdRoot;
      DISPLAY = ":0";
      HOME = "/var/lib/overalls-android";
      JAVA_HOME = "${pkgs.jdk}";
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
      TimeoutStartSec = "600s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/overalls-android" "/run/overalls-android" ];
      ExecStart = "${pkgs.writeShellScript "overalls-android-emulator" ''
        set -eu
        mkdir -p "$HOME/.android"
        mkdir -p "$ANDROID_AVD_HOME"
        if [ ! -f "$ANDROID_AVD_HOME/${avdName}.avd/config.ini" ]; then
          printf 'no\n' | ${sdkRoot}/cmdline-tools/22.0/bin/avdmanager create avd \
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
      ExecStartPost = "${pkgs.writeShellScript "overalls-android-ready" ''
        set -eu
        for _ in $(seq 1 600); do
          if ${sdkRoot}/platform-tools/adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -qx 1; then
            exit 0
          fi
          sleep 1
        done
        exit 1
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
      ExecStart = "${pkgs.x11vnc}/bin/x11vnc -display :0 -rfbport 5901 -localhost -forever -shared -nopw -quiet";
    };
  };

  # The typed relay terminates Lilly's fixed TAP ingress and forwards only to
  # loopback RFB. Lilly authenticates the signed ticket and the relay validates
  # its closed shape before forwarding bytes; no public RFB listener is used.
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
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      CapabilityBoundingSet = "";
      MemoryMax = "128M";
      TasksMax = 32;
      ExecStart = "${pkgs.python3}/bin/python3 ${./android_display_relay.py}";
    };
  };

}
