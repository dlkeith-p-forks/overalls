@echo off
rem Overalls Windows guest post-setup. Runs once as SYSTEM after Windows Setup
rem finishes and before the first logon. It must leave the guest able to boot
rem headless under Firecracker: serial management console on COM1, virtio
rem drivers installed, no sleep, no unattended Windows Update restarts. The
rem one-shot interactive first logon (FirstLogon.cmd) finishes the build: winget
rem packages, static networking, autologon removal, log publication, power-off.
rem
rem Evidence: every step is logged to C:\overalls\setup-complete.log, serial
rem checkpoints go to COM1 for the build driver's timeline, and the Windows
rem Setup logs plus a device inventory are copied onto the EFI system
rem partition so the build can read them from the raw disk without mounting
rem NTFS (see default.nix, mtools).
setlocal
set LOG=C:\overalls\setup-complete.log
set MARKER=C:\overalls\setup-complete
set EVIDENCE=C:\overalls\evidence
mkdir %EVIDENCE% 2>nul
echo [%date% %time%] SetupComplete start >> %LOG%
echo OVERALLS-SETUPCOMPLETE-START > COM1

rem Install every virtio driver shipped on the configuration media. viostor and
rem NetKVM are already in the driver store from Windows PE; this adds the rest
rem (serial, RNG, balloon) so later device additions need no media.
pnputil /add-driver C:\overalls\drivers\*.inf /subdirs /install >> %LOG% 2>&1
echo OVERALLS-DRIVERS-INSTALLED > COM1

rem winget (ADR-0173): provision App Installer for every account here, as
rem SYSTEM; FirstLogon.cmd installs the packages in the interactive first logon.
if exist C:\overalls\winget\packages.txt (
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\overalls\setup\overalls-winget.ps1 -Phase provision >> %LOG% 2>&1
)

rem Power: never sleep, never hibernate. The guest has no display or lid.
powercfg /hibernate off >> %LOG% 2>&1
powercfg /x standby-timeout-ac 0 >> %LOG% 2>&1
powercfg /x monitor-timeout-ac 0 >> %LOG% 2>&1

rem Git attribution is a public SYSTEM-written include shared by guest accounts.
mkdir C:\overalls\git-identity 2>nul
icacls C:\overalls\git-identity /inheritance:r /grant:r "SYSTEM:(OI)(CI)(F)" "Administrators:(OI)(CI)(F)" "Users:(OI)(CI)(RX)" >> %LOG% 2>&1

rem OpenSSH server is an in-box feature on Windows Server 2025. Without the
rem roster agent it starts automatically with its stock configuration; with the
rem agent (ADR-0171 gate 3) it is started on demand by overalls-ssh-sync-windows
rem after the first roster is applied, with the shipped public-key-only
rem configuration and no administrators_authorized_keys.
if exist C:\overalls\agents\overalls-ssh-sync-windows.exe (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Service -Name sshd -StartupType Manual; Stop-Service -Name sshd -ErrorAction SilentlyContinue; Start-Service -Name sshd; Stop-Service -Name sshd" >> %LOG% 2>&1
  mkdir C:\overalls\ssh\authorized_keys 2>nul
  icacls C:\overalls\ssh /inheritance:r /grant:r "SYSTEM:(OI)(CI)(F)" "Administrators:(OI)(CI)(F)" "Users:(OI)(CI)(RX)" >> %LOG% 2>&1
  del /F /Q %ProgramData%\ssh\administrators_authorized_keys 2>nul
  powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-Content C:\overalls\ssh\sshd_config) -replace '__PROGRAMDATA__', ($env:ProgramData -replace '\\', '/') | Set-Content -Encoding ascii $env:ProgramData\ssh\sshd_config" >> %LOG% 2>&1
  findstr /C:"AuthorizedKeysFile C:/overalls/ssh/authorized_keys/%%u" %ProgramData%\ssh\sshd_config >nul 2>&1 && echo OVERALLS-SSHD-CONFIGURED > COM1
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Service -Name sshd -StartupType Automatic; Start-Service -Name sshd" >> %LOG% 2>&1
)
netsh advfirewall firewall add rule name="overalls OpenSSH" dir=in action=allow protocol=TCP localport=22 >> %LOG% 2>&1
netsh advfirewall firewall add rule name="overalls ICMPv4" dir=in action=allow protocol=icmpv4 >> %LOG% 2>&1

rem Windows Update must not reboot a guest on its own schedule.
sc config wuauserv start= disabled >> %LOG% 2>&1
sc stop wuauserv >> %LOG% 2>&1

rem IPv6 off: Lilly guests use a single validated /32 that the bootstrap
rem configures. DHCP stays on until FirstLogon.cmd has installed the winget
rem packages through QEMU user networking, then it is turned off there.
reg add HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters /v DisabledComponents /t REG_DWORD /d 255 /f >> %LOG% 2>&1
echo OVERALLS-GUEST-CONFIGURED > COM1

rem Device and driver inventory for debugging the virtio bindings later.
pnputil /enum-devices /connected > %EVIDENCE%\devices.txt 2>&1
pnputil /enum-drivers > %EVIDENCE%\drivers.txt 2>&1
driverquery /v > %EVIDENCE%\driverquery.txt 2>&1
systeminfo > %EVIDENCE%\systeminfo.txt 2>&1
bcdedit /enum all > %EVIDENCE%\bcd-before-ems.txt 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Disk | Format-List *; Get-Partition | Format-List *; Get-Volume | Format-List *" > %EVIDENCE%\storage.txt 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-NetAdapter | Format-List *; Get-NetIPInterface | Format-List *" > %EVIDENCE%\network.txt 2>&1

rem Boot-time bootstrap: reads Lilly's identity from Firecracker's MMDS and
rem configures the single /32, gateway route and disk growth on every boot
rem (overalls-bootstrap.ps1). Registered as a SYSTEM task so no logon is needed.
schtasks /Create /TN "Overalls\Bootstrap" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\overalls\bootstrap\overalls-bootstrap.ps1" >> %LOG% 2>&1
schtasks /Query /TN "Overalls\Bootstrap" >> %LOG% 2>&1 && echo OVERALLS-BOOTSTRAP-REGISTERED > COM1

rem Guest agents (ADR-0171): SYSTEM tasks started at every boot, each listening
rem on its virtio-vsock port through the viosock provider and publishing its log
rem on the EFI system partition. Present only when the media carries the agents
rem directory. The transport probe (port 1099) is a spike aid; the readiness
rem daemon (port 1024) answers Lilly's boot readiness poll.
if exist C:\overalls\agents\overalls-winprobe.exe (
  schtasks /Create /TN "Overalls\WinProbe" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "C:\overalls\agents\overalls-winprobe.exe" >> %LOG% 2>&1
  schtasks /Query /TN "Overalls\WinProbe" >> %LOG% 2>&1 && echo OVERALLS-WINPROBE-REGISTERED > COM1
)
if exist C:\overalls\agents\overalls-readinessd.exe (
  mkdir C:\overalls\run 2>nul
  schtasks /Create /TN "Overalls\Readinessd" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "C:\overalls\agents\overalls-readinessd.exe" >> %LOG% 2>&1
  schtasks /Query /TN "Overalls\Readinessd" >> %LOG% 2>&1 && echo OVERALLS-READINESSD-REGISTERED > COM1
)
if exist C:\overalls\agents\overalls-trustd-windows.exe (
  schtasks /Create /TN "Overalls\Trustd" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "C:\overalls\agents\overalls-trustd-windows.exe" >> %LOG% 2>&1
  schtasks /Query /TN "Overalls\Trustd" >> %LOG% 2>&1 && echo OVERALLS-TRUSTD-REGISTERED > COM1
)
if exist C:\overalls\agents\overalls-ssh-sync-windows.exe (
  schtasks /Create /TN "Overalls\SshSync" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "C:\overalls\agents\overalls-ssh-sync-windows.exe" >> %LOG% 2>&1
  schtasks /Query /TN "Overalls\SshSync" >> %LOG% 2>&1 && echo OVERALLS-SSHSYNC-REGISTERED > COM1
)
if exist C:\overalls\agents\overalls-host-certificate-windows.exe (
  schtasks /Create /TN "Overalls\HostCertificate" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "C:\overalls\agents\overalls-host-certificate-windows.exe" >> %LOG% 2>&1
  schtasks /Query /TN "Overalls\HostCertificate" >> %LOG% 2>&1 && echo OVERALLS-HOSTCERT-REGISTERED > COM1
)
if exist C:\overalls\agents\overalls-workspaced-windows.exe (
  schtasks /Create /TN "Overalls\Workspaced" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "C:\overalls\agents\overalls-workspaced-windows.exe" >> %LOG% 2>&1
  schtasks /Query /TN "Overalls\Workspaced" >> %LOG% 2>&1 && echo OVERALLS-WORKSPACED-REGISTERED > COM1
)
if exist C:\overalls\agents\overalls-agentd-windows.exe (
  if not exist C:\workspace mkdir C:\workspace
  schtasks /Create /TN "Overalls\Agentd" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "C:\overalls\agents\overalls-agentd-windows.exe" >> %LOG% 2>&1
  schtasks /Query /TN "Overalls\Agentd" >> %LOG% 2>&1 && echo OVERALLS-AGENTD-REGISTERED > COM1
)
if exist C:\overalls\agents\overalls-terminald.exe (
  schtasks /Create /TN "Overalls\Terminald" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "C:\overalls\agents\overalls-terminald.exe" >> %LOG% 2>&1
  schtasks /Query /TN "Overalls\Terminald" >> %LOG% 2>&1 && echo OVERALLS-TERMINALD-REGISTERED > COM1
)
rem Candidate Windows browser editor only: the bundle and broker are supplied
rem together by the image builder. Installation establishes fixed package/task
rem custody and the firewall bound; its marker is required by that candidate.
rem This does not change windows-v1 or select a candidate for fleet admission.
if exist C:\overalls\editor-broker\install.ps1 (
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\overalls\editor-broker\install.ps1 >> %LOG% 2>&1
  if not errorlevel 1 echo OVERALLS-EDITOR-CANDIDATE-INSTALLED > COM1
)
rem schtasks gives every task a 72-hour execution limit; the agents are
rem long-running daemons, so remove the limit, never start a second instance
rem and ask the scheduler to restart a task that fails.
rem EditorBroker and EditorCustodian already have verified private custody and
rem independent supervision settings.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries; Get-ScheduledTask -TaskPath '\Overalls\' | Where-Object { $_.TaskName -notin @('Bootstrap', 'EditorBroker', 'EditorCustodian') } | ForEach-Object { Set-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -Settings $s | Out-Null; 'settings ' + $_.TaskName }" >> %LOG% 2>&1 && echo OVERALLS-AGENT-TASKS-UNBOUNDED > COM1

rem Emergency Management Services: Windows boot manager, loader and the kernel
rem Special Administration Console all use COM1 at 115200 baud from next boot.
bcdedit /emssettings emsport:1 emsbaudrate:115200 >> %LOG% 2>&1
bcdedit /ems {current} on >> %LOG% 2>&1
bcdedit /bootems {bootmgr} on >> %LOG% 2>&1
bcdedit /enum all > %EVIDENCE%\bcd-after-ems.txt 2>&1
echo OVERALLS-EMS-ENABLED > COM1

rem Windows Setup continues with the one-shot autologon; FirstLogon.cmd
rem publishes the logs and powers the guest off.
echo complete > %MARKER%
echo [%date% %time%] SetupComplete end >> %LOG%
echo OVERALLS-SETUPCOMPLETE-DONE > COM1
endlocal
