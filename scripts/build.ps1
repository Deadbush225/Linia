Param(
    [switch]$SkipBuild
)

function Write-Green([string]$Message) {
    Write-Host $Message -ForegroundColor Green
}

function Write-Red([string]$Message) {
    Write-Host $Message -ForegroundColor Red
}

function Write-Blue([string]$Message) {
    Write-Host $Message -ForegroundColor Cyan
}

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $ProjectRoot
Write-Green "Project root: $ProjectRoot"

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Red "Flutter is not installed. Please install Flutter to build the project."
    exit 1
}

if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Write-Red "tar is not installed. Please install tar to create the Linux package."
    exit 1
}

if (-not $SkipBuild) {
    Write-Blue "Starting build process..."

    Write-Blue "Building release versions for Android"
    flutter build apk --release --dart-define-from-file=.env
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Green "Android release build complete."

    Write-Blue "Building release version for Linux"
    flutter build linux --release --dart-define-from-file=.env
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
    Write-Blue "Skipping build..."
}

Write-Blue "Creating package for Linux"
$BundleRoot = Join-Path $ProjectRoot "build/linux/x64/release"
$BundlePath = Join-Path $BundleRoot "bundle"
if (-not (Test-Path $BundleRoot)) {
    Write-Red "Bundle root not found: $BundleRoot"
    exit 1
}

# copy ./install.sh to the bundle directory
$InstallScriptSource = Join-Path $ProjectRoot "linux/install.sh"
Copy-Item $InstallScriptSource -Destination $BundlePath -Force

$DesktopEntrySource = Join-Path $ProjectRoot "linux/linia.desktop"
Copy-Item $DesktopEntrySource -Destination $BundlePath -Force

Set-Location $BundleRoot
$TarPath = Join-Path $BundleRoot "linia-linux-x64.tar.gz"
tar -czvf $TarPath "bundle"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Green "Linux release build complete."
