@echo off
rem Overalls specialize-pass payload copy. Called from the answer file's
rem specialize RunSynchronous command with the drive letter of the boot
rem media as %1 (the command line there is limited to 259 characters, so the
rem logic lives here). Copies the overalls tree to C:\overalls and installs
rem SetupComplete.cmd, then reports over COM1, which exists in the full OS.
setlocal
set SRC=%1:\overalls
echo OVERALLS-SPECIALIZE-COPY src=%SRC% > COM1
mkdir C:\overalls 2>nul
xcopy /E /I /Y /Q %SRC% C:\overalls > C:\overalls\specialize-copy.log 2>&1
mkdir C:\Windows\Setup\Scripts 2>nul
copy /Y %SRC%\setup\SetupComplete.cmd C:\Windows\Setup\Scripts\SetupComplete.cmd >> C:\overalls\specialize-copy.log 2>&1
if exist C:\Windows\Setup\Scripts\SetupComplete.cmd (
  echo OVERALLS-SPECIALIZE-PAYLOAD-OK > COM1
) else (
  echo OVERALLS-SPECIALIZE-PAYLOAD-MISSING > COM1
)
rem Windows Subsystem for Linux (WSL 2): enable its optional features here,
rem because Setup restarts after the specialize pass and completes their
rem installation before first logon. Enabled later, they would leave a pending
rem restart for the first Firecracker boot, which treats a guest reboot as an
rem exit. DISM exit 3010 means "restart required" and is success here.
dism /English /Online /NoRestart /Enable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /All > C:\overalls\specialize-features.log 2>&1
set WSL_RESULT=%ERRORLEVEL%
dism /English /Online /NoRestart /Enable-Feature /FeatureName:VirtualMachinePlatform /All >> C:\overalls\specialize-features.log 2>&1
set VMP_RESULT=%ERRORLEVEL%
set FEATURES=OVERALLS-SPECIALIZE-FEATURES-FAILED
if "%WSL_RESULT%%VMP_RESULT%"=="00" set FEATURES=OVERALLS-SPECIALIZE-FEATURES-ENABLED
if "%WSL_RESULT%%VMP_RESULT%"=="03010" set FEATURES=OVERALLS-SPECIALIZE-FEATURES-ENABLED
if "%WSL_RESULT%%VMP_RESULT%"=="30100" set FEATURES=OVERALLS-SPECIALIZE-FEATURES-ENABLED
if "%WSL_RESULT%%VMP_RESULT%"=="30103010" set FEATURES=OVERALLS-SPECIALIZE-FEATURES-ENABLED
echo %FEATURES% wsl=%WSL_RESULT% vmp=%VMP_RESULT% > COM1
endlocal
exit /b 0
