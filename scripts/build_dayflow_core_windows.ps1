param(
    [ValidateSet("x86", "x64", "ARM64")]
    [string[]] $Architecture = @("x64")
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$manifest = Join-Path $repoRoot "shared-core/Cargo.toml"
$outputRoot = Join-Path $repoRoot "shared-core/dist/windows"

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo is required. Install Rust with rustup before building the Windows shared core."
}

if (-not (Test-Path $manifest)) {
    throw "Rust manifest not found at $manifest"
}

$targetByArchitecture = @{
    "x86" = @{
        RustTarget = "i686-pc-windows-msvc"
        RuntimeIdentifier = "win-x86"
    }
    "x64" = @{
        RustTarget = "x86_64-pc-windows-msvc"
        RuntimeIdentifier = "win-x64"
    }
    "ARM64" = @{
        RustTarget = "aarch64-pc-windows-msvc"
        RuntimeIdentifier = "win-arm64"
    }
}

$installedTargets = @(& rustup target list --installed 2>$null)
if ($LASTEXITCODE -ne 0) {
    throw "rustup is required to verify the installed Windows Rust targets."
}

foreach ($architectureName in $Architecture) {
    $configuration = $targetByArchitecture[$architectureName]
    $rustTarget = $configuration.RustTarget
    $runtimeIdentifier = $configuration.RuntimeIdentifier

    if ($installedTargets -notcontains $rustTarget) {
        throw "Missing Rust target $rustTarget. Install it with: rustup target add $rustTarget"
    }

    & cargo build `
        --manifest-path $manifest `
        --release `
        --features uniffi `
        --target $rustTarget
    if ($LASTEXITCODE -ne 0) {
        throw "Rust shared-core build failed for $rustTarget."
    }

    $library = Join-Path $repoRoot "shared-core/target/$rustTarget/release/dayflow_core.dll"
    if (-not (Test-Path $library)) {
        throw "Rust Windows library was not produced: $library"
    }

    $outputDirectory = Join-Path $outputRoot $runtimeIdentifier
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    Copy-Item -Force $library (Join-Path $outputDirectory "dayflow_core.dll")
    Write-Host "Built $runtimeIdentifier shared core at $outputDirectory/dayflow_core.dll"
}
