@echo off
rem @cc [owner:ghuntley,label:build] project-elixir-language-server-windows
rem Delegate to the project PATH language server and preserve every argument.
where elixir-ls.exe >nul 2>nul
if errorlevel 1 (
  >&2 echo project_elixir_ls_unavailable
  exit /b 127
)
elixir-ls.exe %*
exit /b %ERRORLEVEL%
