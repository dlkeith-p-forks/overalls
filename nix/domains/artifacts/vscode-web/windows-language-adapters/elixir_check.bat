@echo off
rem @cc [owner:ghuntley,label:build] project-elixir-check-windows
rem Delegate to the project PATH Elixir executable and preserve every argument.
where elixir.exe >nul 2>nul
if errorlevel 1 (
  >&2 echo project_elixir_unavailable
  exit /b 127
)
elixir.exe %*
exit /b %ERRORLEVEL%
