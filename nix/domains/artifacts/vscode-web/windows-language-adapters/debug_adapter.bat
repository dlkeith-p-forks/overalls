@echo off
rem @cc [owner:ghuntley,label:build] project-elixir-debug-adapter-windows
rem Delegate to the project PATH debug adapter and preserve every argument.
where elixir-debug-adapter.exe >nul 2>nul
if errorlevel 1 (
  >&2 echo project_elixir_debug_adapter_unavailable
  exit /b 127
)
elixir-debug-adapter.exe %*
exit /b %ERRORLEVEL%
