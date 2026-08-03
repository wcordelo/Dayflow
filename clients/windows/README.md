# Dayflow for Windows

The Windows client is a WinUI 3 shell. `WindowsCaptureAdapter` owns the system
picker and capture-session lifecycle, while
`WindowsGraphicsCaptureFramePipeline` uses a Direct3D11 frame pool and emits
only local derived metadata samples. It never assumes silent desktop capture.
The OS picker and visible capture indication are part of the product UX.
The host also stops the selected source on window/display close, Windows
session lock, and system suspend; resume only returns to an inactive state and
requires a new explicit picker choice.

## Build

On Windows 11 with the .NET 8 SDK, Rust/MSVC, and Visual Studio/Windows App SDK installed:

```powershell
pwsh -File scripts/build_dayflow_core_windows.ps1 -Architecture x64
dotnet restore clients/windows/Dayflow.Windows/Dayflow.Windows.csproj
dotnet build clients/windows/Dayflow.Windows/Dayflow.Windows.csproj -c Debug -p:Platform=x64 -p:RuntimeIdentifier=win-x64
dotnet test clients/windows/Dayflow.Windows.Tests/Dayflow.Windows.Tests.csproj -c Debug -p:Platform=x64 -p:RuntimeIdentifier=win-x64
```

The architecture-specific script builds the Rust library for
`x86_64-pc-windows-msvc`, `i686-pc-windows-msvc`, or
`aarch64-pc-windows-msvc` and writes `dayflow_core.dll` under
`shared-core/dist/windows/<RID>/`. The C# project copies the matching DLL beside
the executable and fails the build if it is missing. Use `-Architecture ARM64`
with `-p:Platform=ARM64 -p:RuntimeIdentifier=win-arm64` for an ARM64 package.
The C ABI wrapper is in `shared-core/include/dayflow_core.h`. `DayflowWindowsSyncSession`
uses the same boundary for sealing, request signing, wrapped-key recovery, and
local projection replay; the C# transport only sends encrypted envelope JSON.
`DayflowAIProviderStore` keeps provider routing and API keys behind DPAPI. The
WinUI chat surface builds a bounded prompt from the local projection and calls
Ollama, Gemini, or an OpenAI-compatible endpoint directly; the sync relay is not
used for inference. `EnqueueCaptureDerived` seals locally derived metadata plus
its source and derivation mode into SQLite without persisting raw frames. The
current adapter uses `privacy_gated_foreground_metadata`; a local AI worker can
produce a richer derived card later without changing the relay contract.
Each frame sample is evaluated through the shared Rust JSON privacy decision
ABI, including optional application/window block rules, before the adapter emits
it to a local derivation sink.
The Direct3D11 frame pool is recreated when a selected window or display changes
size, keeping capture alive across resize and multi-monitor transitions.

After account-key admission, `DayflowWindowsPushNotifications` requests a WNS
channel and registers its URI through the signed encrypted-sync route. A
running packaged client accepts only the one-field
`{"kind":"sync_available"}` raw wake signal and invokes the same coalesced
cursor sync used by window activation; it never treats notification content as
timeline or journal data. WNS package identity, provider credentials, and
background delivery are release gates. The default unpackaged developer path
therefore keeps foreground activation as the reliable fallback.

The current shell is deliberately an unpackaged WinUI 3 build
(`WindowsPackageType=None`) so a developer can validate the native client
without an app identity or signing certificate. The same project now has a
conditional single-project MSIX path. On Windows, after restoring the project,
an unsigned x64 package can be produced with:

```powershell
dotnet build clients/windows/Dayflow.Windows/Dayflow.Windows.csproj `
  -c Release -p:Platform=x64 -p:RuntimeIdentifier=win-x64 `
  -p:DayflowPackaging=true -p:GenerateAppxPackageOnBuild=true `
  -p:AppxPackageSigningEnabled=false `
  -p:AppxPackageDir="$env:TEMP\DayflowPackages\"
Get-ChildItem "$env:TEMP\DayflowPackages" -Recurse -Filter *.msix
```

The package manifest reuses the checked-in Dayflow artwork and keeps the
unpackaged developer path as the default. Signing, installation/upgrade, and
capture lifecycle tests remain release gates. See Microsoft's
[single-project MSIX guidance](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/single-project-msix)
for the Windows App SDK packaging model.

The Win2D package supplies the Direct3D11 device used by
`Direct3D11CaptureFramePool`. The current Mac checkout cannot restore or build
the Windows SDK project; run the native build and capture lifecycle tests on a
Windows 11 host before packaging.

Capture references: [Windows.Graphics.Capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture).

The `Dayflow.Windows.Tests` project runs the C-ABI smoke tests against the
architecture-specific `dayflow_core.dll`: sealing/project replay, the shared
privacy decision, and the four-AM day boundary. It is separate from the WinUI
application so those binding checks do not require a window or capture picker.
