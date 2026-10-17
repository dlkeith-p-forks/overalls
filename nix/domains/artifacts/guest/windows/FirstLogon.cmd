@echo off
rem Overalls Windows image build, final stage (ADR-0173). Runs once from the
rem answer file's FirstLogonCommands in the bootstrap Administrator's one-shot
rem interactive autologon (AutoLogon LogonCount 1), after SetupComplete.cmd.
rem winget needs an interactive logon: it has no package identity as SYSTEM,
rem and its shell launch of .exe installers never returns in a session-0 task.
rem
rem It installs and verifies the pinned winget packages, turns DHCP off,
rem removes every trace of the autologon (and refuses to finish otherwise),
rem returns freed blocks, publishes the logs on the EFI system partition and
rem powers the guest off. The image is refused without OVERALLS-WINGET-COMPLETE
rem and OVERALLS-AUTOLOGON-CLEARED (default.nix).
setlocal
set LOG=C:\overalls\first-logon.log
set EVIDENCE=C:\overalls\evidence
set SETUPLOG=C:\overalls\setup-complete.log
set WINLOGON=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon
echo [%date% %time%] FirstLogon start >> %LOG%
echo OVERALLS-FIRSTLOGON-START > COM1

if exist C:\overalls\winget\packages.txt (
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\overalls\setup\overalls-winget.ps1 -Phase install >> %LOG% 2>&1
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\overalls\setup\overalls-winget.ps1 -Phase verify >> %LOG% 2>&1
)

rem DHCP off: Lilly guests use a single validated /32 that the bootstrap
rem configures; DHCP would be dropped by the host guard.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-NetAdapter | Set-NetIPInterface -AddressFamily IPv4 -Dhcp Disabled" >> %LOG% 2>&1
echo OVERALLS-DHCP-DISABLED > COM1

rem The finished image MUST NOT autologon (windows-serial-console). Windows
rem Setup ends a LogonCount 1 autologon itself; remove its values regardless
rem and prove nothing is left before the image is finished.
reg add "%WINLOGON%" /v AutoAdminLogon /t REG_SZ /d 0 /f >> %LOG% 2>&1
reg delete "%WINLOGON%" /v DefaultPassword /f >> %LOG% 2>&1
reg delete "%WINLOGON%" /v AutoLogonCount /f >> %LOG% 2>&1
reg delete "%WINLOGON%" /v DefaultUserName /f >> %LOG% 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'; if ($w.AutoAdminLogon -eq '0' -and $null -eq $w.DefaultPassword -and $null -eq $w.AutoLogonCount) { exit 0 } else { exit 1 }" >> %LOG% 2>&1 && echo OVERALLS-AUTOLOGON-CLEARED > COM1

rem Return freed blocks so the raw template stays sparse.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Optimize-Volume -DriveLetter C -ReTrim" >> %LOG% 2>&1

rem Publish the Windows Setup logs and the evidence directory on the EFI
rem system partition (FAT32) where the build host reads them with mtools.
echo [%date% %time%] publishing logs to the EFI system partition >> %LOG%
mountvol S: /S >> %LOG% 2>&1
if exist S:\ (
  mkdir S:\overalls\logs 2>nul
  copy /Y C:\Windows\Panther\setupact.log S:\overalls\logs\panther-setupact.log >> %LOG% 2>&1
  copy /Y C:\Windows\Panther\setuperr.log S:\overalls\logs\panther-setuperr.log >> %LOG% 2>&1
  copy /Y C:\Windows\Panther\UnattendGC\setupact.log S:\overalls\logs\unattendgc-setupact.log >> %LOG% 2>&1
  copy /Y C:\Windows\Panther\UnattendGC\setuperr.log S:\overalls\logs\unattendgc-setuperr.log >> %LOG% 2>&1
  copy /Y C:\Windows\INF\setupapi.dev.log S:\overalls\logs\setupapi.dev.log >> %LOG% 2>&1
  copy /Y C:\Windows\INF\setupapi.setup.log S:\overalls\logs\setupapi.setup.log >> %LOG% 2>&1
  copy /Y %SETUPLOG% S:\overalls\logs\setup-complete.log >> %LOG% 2>&1
  xcopy /E /I /Y /Q %EVIDENCE% S:\overalls\logs\evidence >> %LOG% 2>&1
  echo OVERALLS-LOGS-PUBLISHED > COM1
) else (
  echo OVERALLS-LOGS-UNPUBLISHED > COM1
)

rem Final serial report before power-off; this log itself goes last.
echo [%date% %time%] FirstLogon end >> %LOG%
if exist S:\overalls\logs (
  copy /Y %LOG% S:\overalls\logs\first-logon.log >nul 2>&1
  mountvol S: /D >nul 2>&1
)
mode COM1 BAUD=115200 PARITY=n DATA=8 STOP=1 >nul 2>&1
echo OVERALLS-SETUP-COMPLETE > COM1
shutdown /s /t 5 /f /c "overalls image build complete"
endlocal
