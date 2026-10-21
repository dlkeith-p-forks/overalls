{ pkgs, packages }:
let
  sdk = packages.androidSdk;
  sdkRoot = "${sdk}/libexec/android-sdk";
  fixtureApk = pkgs.runCommand "overalls-android-fixture-apk" {
    nativeBuildInputs = [ pkgs.jdk pkgs.unzip pkgs.zip ];
  } ''
    set -euo pipefail
    buildTools=$(find -L ${sdkRoot}/build-tools -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
    platform=${sdkRoot}/platforms/android-36
    test -x "$buildTools/aapt2" -a -x "$buildTools/d8" -a -x "$buildTools/apksigner"
    test -f "$platform/android.jar"
    export HOME="$TMPDIR/home"
    mkdir -p src/classes dex linked apk "$HOME/.android"
    keytool -genkeypair -keystore "$HOME/.android/debug.keystore" -storepass android \
      -alias androiddebugkey -keypass android -dname "CN=Android Debug,O=Android,C=US" \
      -keyalg RSA -validity 10000
    cp ${./app/AndroidManifest.xml} src/AndroidManifest.xml
    cp ${./app/MainActivity.java} src/MainActivity.java
    javac --release 8 -classpath "$platform/android.jar" -d src/classes src/MainActivity.java
    ${pkgs.jdk}/bin/jar cf classes.jar -C src/classes .
    "$buildTools/d8" --lib "$platform/android.jar" --output dex classes.jar
    "$buildTools/aapt2" link -I "$platform/android.jar" \
      --manifest src/AndroidManifest.xml --no-compress -o linked/unsigned.apk
    cd apk
    ${pkgs.unzip}/bin/unzip -q ../linked/unsigned.apk
    cp ../dex/classes.dex .
    ${pkgs.zip}/bin/zip -q -r -0 ../unsigned.apk resources.arsc
    ${pkgs.zip}/bin/zip -q -r ../unsigned.apk . -x resources.arsc
    cd ..
    "$buildTools/zipalign" -P 4 -f 4 unsigned.apk aligned.apk
    mkdir -p "$out"
    "$buildTools/apksigner" sign --ks "$HOME/.android/debug.keystore" \
      --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android \
      --out "$out/fixture.apk" aligned.apk
  '';
  emulatorScript = pkgs.writeShellScript "android-emulator-software" ''
    set -euo pipefail
    export ANDROID_HOME=${sdkRoot}
    export ANDROID_SDK_ROOT=${sdkRoot}
    export ANDROID_USER_HOME=/var/lib/android-test
    export ANDROID_AVD_HOME=/var/lib/android-test/avd
    export DISPLAY=:0
    mkdir -p "$HOME/.android"
    if [ ! -f "$HOME/.android/adbkey" ]; then
      ${pkgs.android-tools}/bin/adb keygen "$HOME/.android/adbkey"
    fi
    # The emulator imports the persisted HOME/.android key into Android user state.
    # Do not disable ADB authentication or supply the unsupported -auth option.
    mkdir -p "$ANDROID_AVD_HOME"
    if [ ! -f "$ANDROID_AVD_HOME/overalls-test.avd/config.ini" ]; then
      printf 'no\n' | ${sdkRoot}/cmdline-tools/22.0/bin/avdmanager create avd \
        --force --name overalls-test \
        --package 'system-images;android-34;google_apis;x86_64' \
        --path "$ANDROID_AVD_HOME/overalls-test.avd"
      cat >> "$ANDROID_AVD_HOME/overalls-test.avd/config.ini" <<'CONFIG'
hw.gpu.enabled = yes
hw.gpu.mode = swiftshader_indirect
hw.keyboard = yes
hw.cpu.ncore = 4
hw.ramSize = 4096
hw.lcd.width = 480
hw.lcd.height = 800
hw.lcd.density = 160
CONFIG
    fi
    exec ${sdkRoot}/emulator/emulator -avd overalls-test \
      -no-accel -gpu swiftshader_indirect -noaudio \
      -no-boot-anim -no-snapshot \
      -ports 5554,5555
  '';
in
pkgs.testers.runNixOSTest {
  name = "overalls-android-emulator-software";
  globalTimeout = 1800;
  nodes.android = { ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 8192;
    virtualisation.cores = 8;
    virtualisation.diskSize = 32768;
    environment.systemPackages = [ pkgs.android-tools pkgs.gawk pkgs.xorg.xorgserver pkgs.jdk sdk ];
    users.users.android-test = {
      isSystemUser = true;
      group = "android-test";
    };
    users.groups.android-test = { };
    systemd.services.android-test-display = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "android-test";
        Group = "android-test";
        ExecStart = "${pkgs.xorg.xorgserver}/bin/Xvfb :0 -screen 0 1080x1920x24 -nolisten tcp -ac -noreset";
      };
    };
    systemd.services.android-test-emulator = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "android-test-display.service" ];
      after = [ "android-test-display.service" ];
      path = [ pkgs.coreutils pkgs.gawk ];
      environment = {
        HOME = "/var/lib/android-test";
        JAVA_HOME = "${pkgs.jdk}";
      };
      serviceConfig = {
        Type = "simple";
        User = "android-test";
        Group = "android-test";
        StateDirectory = "android-test";
        ExecStart = emulatorScript;
        Restart = "on-failure";
        TimeoutStopSec = 300;
      };
    };
  };
  # @cc [owner:ghuntley,label:verification;isolation] android-emulator-software-machine
  # The machine check MUST observe an actual Android emulator process using
  # software rendering, with no /dev/kvm, and obtain a boot-complete property
  # and PNG screencap through the real adb client. This is software-emulator
  # evidence only; it does not establish Firecracker, guest isolation, native
  # KVM, production Lilly authority, or multi-host recovery.
  testScript = ''
    android.start()
    android.wait_for_unit("android-test-emulator.service")
    android.wait_until_succeeds("pid=$(systemctl show -p MainPID --value android-test-emulator.service); test \"$pid\" -gt 0; tr '\\0' ' ' < /proc/$pid/cmdline | grep -F '/emulator'", timeout=120)
    cmdline = android.succeed("pid=$(systemctl show -p MainPID --value android-test-emulator.service); tr '\\0' ' ' < /proc/$pid/cmdline")
    assert "-no-accel" in cmdline, cmdline
    assert "-gpu swiftshader_indirect" in cmdline, cmdline
    assert "-skip-adb-auth" not in cmdline and "-skip_adb_auth" not in cmdline
    android.wait_for_open_port(5555)
    android.succeed("export HOME=/var/lib/android-test; adb kill-server; adb start-server")
    android.succeed("HOME=/var/lib/android-test adb connect 127.0.0.1:5555")
    android.wait_until_succeeds("HOME=/var/lib/android-test timeout 15 adb -s 127.0.0.1:5555 wait-for-device", timeout=600)
    try:
      android.wait_until_succeeds('test "$(HOME=/var/lib/android-test timeout 15 adb -s 127.0.0.1:5555 shell getprop sys.boot_completed | tr -d \'\\r\')" = 1', timeout=1200)
    except Exception:
      print(android.succeed("HOME=/var/lib/android-test adb devices -l || true"))
      print(android.succeed("systemctl status android-test-emulator.service --no-pager || true"))
      print(android.succeed("HOME=/var/lib/android-test timeout 15 adb -s 127.0.0.1:5555 shell getprop || true"))
      raise
    android.succeed("HOME=/var/lib/android-test adb -s 127.0.0.1:5555 shell getprop ro.kernel.qemu | grep -Fx 1")
    android.wait_until_succeeds('HOME=/var/lib/android-test timeout 15 adb -s 127.0.0.1:5555 shell cmd package list packages | grep -F package:', timeout=360)
    android.succeed("HOME=/var/lib/android-test adb -s 127.0.0.1:5555 install -r ${fixtureApk}/fixture.apk | grep -F Success")
    android.succeed("HOME=/var/lib/android-test adb -s 127.0.0.1:5555 shell am start -n com.overalls.androidfixture/.MainActivity | grep -F cmp=com.overalls.androidfixture/.MainActivity")
    android.wait_until_succeeds("HOME=/var/lib/android-test adb -s 127.0.0.1:5555 shell run-as com.overalls.androidfixture cat files/marker | grep -Fx overalls-android-fixture-v1", timeout=60)
    android.succeed("HOME=/var/lib/android-test adb -s 127.0.0.1:5555 shell settings get global animator_duration_scale")
    android.succeed("HOME=/var/lib/android-test adb -s 127.0.0.1:5555 exec-out screencap -p > /tmp/android-screencap.png")
    android.succeed("test $(stat -c %s /tmp/android-screencap.png) -gt 100")
    android.succeed("head -c 8 /tmp/android-screencap.png | od -An -t x1 | grep -F '89 50 4e 47 0d 0a 1a 0a'")
    android.succeed("systemctl mask --runtime android-test-emulator.service")
    android.succeed("systemctl kill --kill-who=all --signal=KILL android-test-emulator.service || true")
    android.succeed("systemctl stop android-test-emulator.service")
    android.succeed("systemctl reset-failed android-test-emulator.service || true")
    android.wait_until_succeeds('test "$(systemctl show -p ActiveState --value android-test-emulator.service)" = inactive', timeout=360)
    android.succeed("systemctl unmask android-test-emulator.service")
    android.succeed("systemctl start android-test-emulator.service")
    android.wait_for_open_port(5555)
    android.wait_until_succeeds("HOME=/var/lib/android-test adb connect 127.0.0.1:5555 | grep -E 'connected|already connected'", timeout=60)
    android.wait_until_succeeds("HOME=/var/lib/android-test timeout 15 adb -s 127.0.0.1:5555 wait-for-device", timeout=600)
    android.wait_until_succeeds('test "$(HOME=/var/lib/android-test timeout 15 adb -s 127.0.0.1:5555 shell getprop sys.boot_completed | tr -d \"\\r\")" = 1', timeout=1200)
  '';
}
