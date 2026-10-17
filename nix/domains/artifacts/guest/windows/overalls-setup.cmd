@echo off
rem Overalls Windows PE launcher, injected into boot.wim and started by
rem winpeshl.ini instead of the media's default Setup entry point.
rem
rem Windows Server 2025 media starts the new "ConX" Setup (SetupPrep.exe), which
rem fails its Windows PE initialization under QEMU and does not process the
rem answer file reliably. The legacy setup.exe still ships in boot.wim and is
rem selected with /legacy. The installation source is Microsoft's own ISO on
rem the second CD drive; the answer file and drivers are on the boot media.
setlocal
wpeinit
set SRC=
set CFG=
for %%d in (C D E F G H I J K L) do (
  if exist %%d:\sources\install.wim set SRC=%%d:\sources\install.wim
  if exist %%d:\autounattend.xml set CFG=%%d:\autounattend.xml
)
echo OVERALLS-WINPE-LAUNCH source=%SRC% answer=%CFG% > X:\overalls-launch.txt
if "%SRC%"=="" goto :missing
if "%CFG%"=="" goto :missing
X:\sources\setup.exe /legacy /installfrom:%SRC% /unattend:%CFG%
echo OVERALLS-WINPE-SETUP-RETURNED %errorlevel% >> X:\overalls-launch.txt
goto :eof
:missing
echo OVERALLS-WINPE-MEDIA-MISSING >> X:\overalls-launch.txt
rem Leave a prompt for the forensics step (Shift+F10 is not needed here).
cmd.exe
