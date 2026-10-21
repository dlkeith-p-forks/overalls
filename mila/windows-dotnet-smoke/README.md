# Windows Rust interop smoke

This .NET 10 console executable links the production `RustNative.cs` without
WinUI or test-framework dependencies. Run after the production Windows build:

```powershell
dotnet run --project mila/windows-dotnet-smoke --configuration Release -p:MilaNativeDll=C:\absolute\path\to\staged\mila_native.dll
```

`MilaNativeDll` is required and must exist. The project copies it beside its
executable. A missing library or export fails the ABI-version assertion; the
production `Unavailable` fallback never passes. Checks cover a host-qualified
route, invalid-route refusal, snapshot summary layout including a timestamp
larger than 32 bits, wrong host/port, malformed and oversized snapshots, and
short route output preserving both guard bytes and the reported length.

The `windows-native` job passes the DLL staged by the WinUI build, rather than
an independently supplied test implementation. These checks establish only the
invoked adapter behavior, not UI, device custody or lifecycle acceptance.
