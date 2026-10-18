# SA (System Architecture) Windows Installer
#
# PowerShell installer script for native Windows environments.
# Installs to $HOME\.sa and updates the user's environment.
#
# Usage:
#   irm https://example.com/install.ps1 | iex
#   .\install.ps1 [options]
#
# Options:
#   -Help              Show this help message and exit
#   -Version <tag>     Install a specific release tag (e.g. v0.3.1)
#   -Dir <path>        Override installation directory (default: $HOME\.sa)
#   -NoShell           Skip user PATH modification
#   -DryRun            Print what would be done without making changes

[CmdletBinding()]
param(
    [switch]$Help,
    [string]$Version = "",
    [string]$Dir = "",
    [switch]$NoShell,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ── Helpers ─────────────────────────────────────────────────────────────────

function Write-Info   ($msg) { Write-Host "[i] $msg" -ForegroundColor Blue }
function Write-Step   ($msg) { Write-Host "[>] $msg" -ForegroundColor Cyan }
function Write-Ok     ($msg) { Write-Host "[✓] $msg" -ForegroundColor Green }
function Write-Warn   ($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err    ($msg) { Write-Error "[✗] Error: $msg" }

function Invoke-OrEcho {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) {
        Write-Host "  dry-run: $Description" -ForegroundColor Yellow
    } else {
        & $Action
    }
}

function Test-StdPayload {
    param([string]$StdRoot)
    $required = @(
        "io\print.sai",
        "core\sa_core.sars",
        "core\result.sars",
        "core\option.sars",
        "sa_std.h",
        "sa_std.lib"
    )
    foreach ($rel in $required) {
        $path = Join-Path $StdRoot $rel
        if (-not (Test-Path $path)) {
            Write-Err "Installed std payload is incomplete: missing std\$rel"
        }
    }
}

# ── Header ───────────────────────────────────────────────────────────────────

function Print-Header {
    Write-Host "   _____         " -ForegroundColor Magenta
    Write-Host "  / ___/ ____ _  " -ForegroundColor Magenta
    Write-Host "  \__ \ / __ ``/  " -ForegroundColor Magenta
    Write-Host " ___/ // /_/ /   " -ForegroundColor Magenta
    Write-Host "/____/ \__,_/     " -NoNewline -ForegroundColor Magenta
    Write-Host "System Architecture Toolchain" -ForegroundColor Cyan
    Write-Host "                 Linear Ownership & Zero-Trust Assembly`n" -ForegroundColor Cyan
}

# ── Help ─────────────────────────────────────────────────────────────────────

function Print-Help {
    Print-Header
    Write-Host "Install the SA toolchain to your Windows system.`n"
    Write-Host "USAGE" -ForegroundColor White
    Write-Host "  .\install.ps1 [options]`n"
    Write-Host "OPTIONS" -ForegroundColor White
    $opts = @(
        @("-Help",              "Show this help message and exit"),
        @("-Version <tag>",     "Install a specific release tag (e.g. v0.3.1)"),
        @("-Dir <path>",        "Override installation directory (default: `$HOME\.sa)"),
        @("-NoShell",           "Skip user PATH/environment modification"),
        @("-DryRun",            "Print what would be done without making changes")
    )
    foreach ($o in $opts) {
        Write-Host ("  {0,-24} {1}" -f $o[0], $o[1])
    }
    Write-Host "`nEXAMPLES" -ForegroundColor White
    Write-Host "  .\install.ps1"
    Write-Host "  .\install.ps1 -Version v0.3.1"
    Write-Host "  .\install.ps1 -Dir C:\tools\sa -NoShell"
    Write-Host "  .\install.ps1 -DryRun`n"
}

# ── Main ─────────────────────────────────────────────────────────────────────

if ($Help) {
    Print-Help
    exit 0
}

Print-Header

if ($DryRun) {
    Write-Warn "Running in dry-run mode — no files will be written.`n"
}

# Architecture detection
$arch = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    "X64" { "x86_64" }
    "Arm64" { "aarch64" }
    default { Write-Err "Unsupported Windows architecture: $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
}
Write-Info "Detected platform: windows-$arch"

# Installation directories
$saDir    = if ($Dir -ne "") { $Dir } else { Join-Path $HOME ".sars" }
$saBinDir = Join-Path $saDir "bin"
$saStdDir = Join-Path $saDir "std"

Write-Info "Installation directory: $saDir"

Invoke-OrEcho "Create $saBinDir" { New-Item -ItemType Directory -Force -Path $saBinDir | Out-Null }
Invoke-OrEcho "Create $saStdDir" { New-Item -ItemType Directory -Force -Path $saStdDir | Out-Null }

# Release URL
$defaultBase = "https://github.com/sci/sa/releases"
$releaseUrl  = if ($env:SA_RELEASE_URL) {
    $env:SA_RELEASE_URL
} elseif ($Version -ne "") {
    Write-Info "Pinned release: $Version"
    "$defaultBase/download/$Version"
} else {
    "$defaultBase/latest/download"
}

$zipName        = "sa-windows-$arch.zip"
$downloadUrl    = "$releaseUrl/$zipName"
$checksumUrl    = "$releaseUrl/$zipName.sha256"
$tempZip        = Join-Path $env:TEMP $zipName
$tempExtractDir = Join-Path $env:TEMP "sa_install_temp"

if ($DryRun) {
    Write-Step "Would download: $downloadUrl"
    Write-Step "Would verify checksum from: $checksumUrl"
    Write-Step "Would extract to: $saBinDir and $saStdDir"
} else {
    Write-Step "Downloading SA package archive"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
        Write-Ok "Download complete."

        # Checksum verification (best-effort)
        Write-Step "Verifying checksum"
        try {
            $checksumContent = (Invoke-WebRequest -Uri $checksumUrl -UseBasicParsing).Content.Trim()
            $expectedHash = ($checksumContent -split '\s+')[0].ToUpper()
            $actualHash   = (Get-FileHash -Path $tempZip -Algorithm SHA256).Hash.ToUpper()
            if ($actualHash -eq $expectedHash) {
                Write-Ok "Checksum verified."
            } else {
                Write-Err "Checksum mismatch!`n  expected: $expectedHash`n  got:      $actualHash"
            }
        } catch {
            Write-Warn "No checksum file found at $checksumUrl — skipping verification."
        }

        Write-Step "Extracting toolchain files"
        if (Test-Path $tempExtractDir) { Remove-Item -Recurse -Force $tempExtractDir }
        Expand-Archive -Path $tempZip -DestinationPath $tempExtractDir -Force
        Write-Ok "Extraction complete."

        $extractedRoot = $tempExtractDir
        $rootDirs = @(Get-ChildItem -Path $tempExtractDir -Directory)
        if ($rootDirs.Count -eq 1) {
            $extractedRoot = $rootDirs[0].FullName
        }

        $exePath = Join-Path $extractedRoot "bin\sa.exe"
        if (Test-Path $exePath) {
            Copy-Item -Path $exePath -Destination (Join-Path $saBinDir "sa.exe") -Force
        } else {
            throw "Invalid archive structure: bin\sa.exe not found."
        }

        $stdPath = Join-Path $extractedRoot "std"
        if (Test-Path $stdPath) {
            Copy-Item -Path "$stdPath\*" -Destination $saStdDir -Recurse -Force
        } else {
            throw "Invalid archive structure: std not found."
        }
        Test-StdPayload $saStdDir

        Remove-Item -Recurse -Force $tempExtractDir
        Remove-Item -Force $tempZip

    } catch {
        Write-Warn "Failed to fetch precompiled release: $_"

        if (Get-Command "zig" -ErrorAction SilentlyContinue) {
            Write-Info "'zig' found — attempting to build from source..."
            try {
                Start-Process -FilePath "zig" -ArgumentList "build -Doptimize=ReleaseSafe" -NoNewWindow -Wait
                if (Test-Path "zig-out\bin\sa.exe") {
                    Copy-Item -Path "zig-out\bin\sa.exe" -Destination (Join-Path $saBinDir "sa.exe") -Force
                }
                if (Test-Path "sa_std") {
                    Copy-Item -Path "sa_std\*" -Destination $saStdDir -Recurse -Force
                }
                if (Test-Path "zig-out\lib\sa_std.lib") {
                    Copy-Item -Path "zig-out\lib\sa_std.lib" -Destination (Join-Path $saStdDir "sa_std.lib") -Force
                }
                if (Test-Path "src\runtime\sa_std.h") {
                    Copy-Item -Path "src\runtime\sa_std.h" -Destination (Join-Path $saStdDir "sa_std.h") -Force
                }
                Test-StdPayload $saStdDir
                Write-Ok "Built from source."
            } catch {
                Write-Err "Local source build failed: $_"
            }
        } else {
            Write-Err "Remote download failed and 'zig' is not installed for a local build."
        }
    }
}

# PATH update
if (-not $NoShell) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$saBinDir*") {
        Invoke-OrEcho "Add $saBinDir to user PATH" {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$saBinDir", "User")
            [Environment]::SetEnvironmentVariable("SA_STD_DIR", $saStdDir, "User")
        }
        Write-Ok "PATH updated."
    } else {
        Write-Info "SA bin directory is already in user PATH."
    }
}

Write-Host ""
Write-Ok "SA Toolchain installed successfully!"
Write-Host "  Executable:  $saBinDir\sa.exe" -ForegroundColor Green
Write-Host "  Std Library Root: $saStdDir`n" -ForegroundColor Green

if ($DryRun) {
    Write-Info "(dry-run: no files were written)"
} elseif ($NoShell) {
    Write-Info "Shell modification skipped (-NoShell)."
    Write-Host "  Add this to your profile to activate SA:"
    Write-Host "    `$env:Path += `";$saBinDir`""
} else {
    Write-Warn "Restart your terminal, or run to activate immediately:"
    Write-Host "  `$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User')"
}
Write-Host ""
