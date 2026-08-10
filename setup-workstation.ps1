#Requires -Version 5.1
<#
    Windows workstation setup

    Installs core dev tools and restores a VS Code profile (settings +
    extensions).

    Run from an elevated PowerShell prompt, in the same folder as your
    exported '*.code-profile' file.
#>

Clear-Host
Write-Host " __        __         _        _        _   _" -ForegroundColor Cyan
Write-Host " \ \      / /__  _ __| | _____| |_ __ _| |_(_) ___  _ __" -ForegroundColor Cyan
Write-Host "  \ \ /\ / / _ \| '__| |/ / __| __/ _`` | __| |/ _ \| '_ \" -ForegroundColor Cyan
Write-Host "   \ V  V / (_) | |  |   <\__ \ || (_| | |_| | (_) | | | |" -ForegroundColor Cyan
Write-Host "    \_/\_/ \___/|_|  |_|\_\___/\__\__,_|\__|_|\___/|_| |_|" -ForegroundColor Cyan
Write-Host " "
Write-Host "            S E T U P   S C R I P T" -ForegroundColor Yellow
Write-Host "==============================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Starting workstation deployment..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Pull machine + user environment back into this process. Needed after any
# installer that writes PATH or creates new env vars (git, nvm, vscode).
function Update-SessionEnvironment {
    foreach ($name in 'Path', 'NVM_HOME', 'NVM_SYMLINK') {
        $machine = [System.Environment]::GetEnvironmentVariable($name, 'Machine')
        $user    = [System.Environment]::GetEnvironmentVariable($name, 'User')

        if ($name -eq 'Path') {
            $combined = @($machine, $user) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd(';') }
            $env:Path = ($combined -join ';')
        }
        else {
            $value = if ($user) { $user } else { $machine }
            if ($value) { Set-Item -Path "env:$name" -Value $value }
        }
    }
}

# Locate winget. It may exist but not be on PATH yet (fresh install, or a
# session started before App Installer registered), so check the known
# WindowsApps shim location too.
function Resolve-WingetCommand {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $shim = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $shim) { return $shim }

    return $null
}

# Install App Installer (which provides winget) from the Microsoft Store
# package. Needed on Windows Sandbox and some stripped/LTSC images, where it
# is absent by default.
function Install-WingetBootstrap {
    Write-Host "Bootstrapping winget (App Installer)..." -ForegroundColor Green

    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $temp = Join-Path $env:TEMP "winget-bootstrap-$(Get-Random)"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    try {
        # winget's own dependencies must be installed first, in this order.
        $downloads = @(
            @{ Name = 'VCLibs';  Url = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'; File = 'vclibs.appx' },
            @{ Name = 'UI.Xaml'; Url = 'https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.6'; File = 'uixaml.zip' },
            @{ Name = 'winget';  Url = 'https://aka.ms/getwinget'; File = 'winget.msixbundle' }
        )

        foreach ($item in $downloads) {
            Write-Host "   Downloading $($item.Name)..." -ForegroundColor DarkGray
            Invoke-WebRequest -Uri $item.Url -OutFile (Join-Path $temp $item.File) -UseBasicParsing
        }

        # The UI.Xaml nuget package is a zip; the appx lives inside it.
        $xamlZip = Join-Path $temp 'uixaml.zip'
        $xamlDir = Join-Path $temp 'uixaml'
        Expand-Archive -Path $xamlZip -DestinationPath $xamlDir -Force
        $xamlAppx = Get-ChildItem -Path $xamlDir -Recurse -Filter '*.appx' |
            Where-Object { $_.FullName -match 'x64' } |
            Select-Object -First 1

        if (-not $xamlAppx) { throw "Could not find the x64 appx inside the UI.Xaml package." }

        Add-AppxPackage -Path (Join-Path $temp 'vclibs.appx') -ErrorAction Stop
        Add-AppxPackage -Path $xamlAppx.FullName -ErrorAction Stop
        Add-AppxPackage -Path (Join-Path $temp 'winget.msixbundle') -ErrorAction Stop

        Update-SessionEnvironment
        Start-Sleep -Seconds 2   # the WindowsApps shim takes a moment to register

        $resolved = Resolve-WingetCommand
        if ($resolved) {
            Write-Host "   OK: winget is available." -ForegroundColor DarkGray
            return $resolved
        }

        Write-Warning "App Installer registered but winget still isn't resolvable in this session."
        return $null
    }
    catch {
        Write-Warning "winget bootstrap failed: $($_.Exception.Message)"
        return $null
    }
    finally {
        $ProgressPreference = $previousProgress
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# winget wrapper that actually reports failures instead of silently continuing.
function Install-WingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $DisplayName
    )

    if (-not $script:WingetExe) {
        Write-Warning "Skipping $DisplayName - winget is not available."
        return $false
    }

    Write-Host "Installing $DisplayName..." -ForegroundColor Green
    & $script:WingetExe install -e --id $Id --accept-package-agreements --accept-source-agreements
    $code = $LASTEXITCODE

    # 0 = installed, 0x8A15002B (-1978335189) = already installed / no upgrade found
    if ($code -eq 0 -or $code -eq -1978335189 -or $code -eq -1978335212) {
        Write-Host "   OK: $DisplayName" -ForegroundColor DarkGray
        return $true
    }

    Write-Warning "$DisplayName install returned exit code $code. Continuing, but check this."
    return $false
}

# Locate code.cmd even if PATH hasn't caught up yet.
function Get-VSCodeCli {
    $cmd = Get-Command code -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        'C:\Program Files\Microsoft VS Code\bin\code.cmd',
        'C:\Program Files (x86)\Microsoft VS Code\bin\code.cmd'
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 0. Locate and parse the VS Code profile
# ---------------------------------------------------------------------------

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Pick up whatever profile the user exported from VS Code — the filename is
# whatever they named their profile, so match on extension instead.
$ProfileCandidates = @(Get-ChildItem -Path $ScriptDir -Filter '*.code-profile' -File -ErrorAction SilentlyContinue)

if ($ProfileCandidates.Count -eq 0) {
    Write-Error "No '*.code-profile' file found in $ScriptDir. Export one from VS Code (gear icon > Profiles > Export Profile) and save it next to this script."
    exit 1
}

if ($ProfileCandidates.Count -gt 1) {
    Write-Warning "Multiple .code-profile files found. Using '$($ProfileCandidates[0].Name)'."
}

$ProfileFile = $ProfileCandidates[0].FullName
Write-Host "Using VS Code profile: $($ProfileCandidates[0].Name)" -ForegroundColor DarkGray

try {
    $ProfileData = Get-Content $ProfileFile -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Error "Could not parse '$($ProfileCandidates[0].Name)' as JSON: $($_.Exception.Message)"
    exit 1
}

# VS Code stores 'settings' and 'extensions' as JSON-encoded *strings* inside
# the profile. Handle both that and the already-deserialized case.
function ConvertFrom-ProfileSection {
    param($Section)
    if ($null -eq $Section) { return $null }
    if ($Section -is [string]) { return ($Section | ConvertFrom-Json) }
    return $Section
}

$SettingsRoot   = ConvertFrom-ProfileSection $ProfileData.settings
$ExtensionsList = ConvertFrom-ProfileSection $ProfileData.extensions

# The settings blob is itself { "settings": "{...}" } in some exports.
$SettingsObj = $SettingsRoot
if ($SettingsRoot -and $SettingsRoot.PSObject.Properties.Name -contains 'settings') {
    $SettingsObj = ConvertFrom-ProfileSection $SettingsRoot.settings
}

if (-not $SettingsObj) {
    Write-Warning "No settings found in the profile. VS Code settings.json will be left untouched."
}

# ---------------------------------------------------------------------------
# 0b. Ensure winget is available
# ---------------------------------------------------------------------------

$script:WingetExe = Resolve-WingetCommand

if (-not $script:WingetExe) {
    Write-Warning "winget was not found. This is normal on Windows Sandbox and some stripped Windows images."
    $reply = Read-Host "Attempt to install App Installer automatically? (y/N)"

    if ($reply -match '^(y|yes)$') {
        $script:WingetExe = Install-WingetBootstrap
    }
}

if (-not $script:WingetExe) {
    Write-Error @"
winget is required and unavailable, so no packages can be installed.

Fix it one of these ways, then re-run this script:
  * Install "App Installer" from the Microsoft Store
  * Download it manually from https://aka.ms/getwinget
  * On Windows Sandbox, re-run this script and accept the bootstrap prompt
    (it needs an internet connection)
"@
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Core tools (Git & NVM)
# ---------------------------------------------------------------------------

Install-WingetPackage -Id 'Git.Git' -DisplayName 'Git' | Out-Null
Install-WingetPackage -Id 'CoreyButler.NVMforWindows' -DisplayName 'NVM for Windows' | Out-Null

Update-SessionEnvironment

# ---------------------------------------------------------------------------
# 2. Node LTS
# ---------------------------------------------------------------------------

if (Get-Command nvm -ErrorAction SilentlyContinue) {
    Write-Host "Installing latest Node LTS..." -ForegroundColor Green
    nvm install lts
    nvm use lts
    Update-SessionEnvironment

    if (Get-Command node -ErrorAction SilentlyContinue) {
        Write-Host "   Node: $(node --version)" -ForegroundColor DarkGray
    }
    else {
        Write-Warning "Node isn't on PATH yet. Open a new terminal and run: nvm use lts"
    }
}
else {
    Write-Warning "nvm not available in this session. Open a new terminal and run: nvm install lts; nvm use lts"
}

# ---------------------------------------------------------------------------
# 3. Flutter SDK
# ---------------------------------------------------------------------------

Write-Host "Setting up Flutter SDK..." -ForegroundColor Green
$FlutterDir = 'C:\flutter'
$FlutterBin = Join-Path $FlutterDir 'bin'

if (-not (Test-Path $FlutterDir)) {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        git clone https://github.com/flutter/flutter.git -b stable $FlutterDir
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Flutter clone failed (exit $LASTEXITCODE). Skipping PATH update."
        }
    }
    else {
        Write-Warning "git not available in this session. Skipping Flutter clone."
    }
}
else {
    Write-Host "   Flutter folder already exists at $FlutterDir." -ForegroundColor DarkGray
}

if (Test-Path $FlutterBin) {
    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($UserPath -notmatch [regex]::Escape($FlutterBin)) {
        $newPath = ($UserPath.TrimEnd(';') + ';' + $FlutterBin).TrimStart(';')
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Update-SessionEnvironment
        Write-Host "   Flutter added to user PATH." -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# 4. Visual Studio Code
# ---------------------------------------------------------------------------

Install-WingetPackage -Id 'Microsoft.VisualStudioCode' -DisplayName 'Visual Studio Code' | Out-Null
Update-SessionEnvironment

# ---------------------------------------------------------------------------
# 5. Inject VS Code settings
# ---------------------------------------------------------------------------

if ($SettingsObj) {
    Write-Host "Injecting VS Code settings..." -ForegroundColor Green

    $TargetSettingsDir = Join-Path ([System.Environment]::GetFolderPath('ApplicationData')) 'Code\User'
    if (-not (Test-Path $TargetSettingsDir)) {
        New-Item -ItemType Directory -Path $TargetSettingsDir -Force | Out-Null
    }

    $TargetSettingsFile = Join-Path $TargetSettingsDir 'settings.json'

    if (Test-Path $TargetSettingsFile) {
        $backup = "$TargetSettingsFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $TargetSettingsFile $backup -Force
        Write-Host "   Existing settings backed up to $(Split-Path $backup -Leaf)" -ForegroundColor DarkGray
    }

    # Serialize properly, and write UTF-8 without BOM so VS Code stays happy.
    $json = $SettingsObj | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $TargetSettingsFile,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Write-Host "   settings.json written." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 6. Install extensions
# ---------------------------------------------------------------------------

$CodeCli = Get-VSCodeCli

if (-not $CodeCli) {
    Write-Warning "VS Code CLI not found. Open a new terminal and re-run the extension step manually."
}
elseif (-not $ExtensionsList) {
    Write-Warning "No extensions listed in the profile."
}
else {
    Write-Host "Installing extensions..." -ForegroundColor Green
    $failed = @()

    foreach ($ext in $ExtensionsList) {
        $extId = if ($ext.identifier -and $ext.identifier.id) { $ext.identifier.id }
                 elseif ($ext.id) { $ext.id }
                 else { $null }

        if (-not $extId) { continue }

        Write-Host " -> $extId" -ForegroundColor DarkGray
        & $CodeCli --install-extension $extId --force | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed += $extId }
    }

    if ($failed.Count -gt 0) {
        Write-Warning "These extensions failed to install:"
        $failed | ForEach-Object { Write-Warning "   $_" }
    }
}

# ---------------------------------------------------------------------------
# 7. Optional apps
# ---------------------------------------------------------------------------

Write-Host "----------------------------------------------" -ForegroundColor Gray

if ((Read-Host "Install Figma? (y/N)") -match '^[yY]$') {
    Install-WingetPackage -Id 'Figma.Figma' -DisplayName 'Figma' | Out-Null
}

if ((Read-Host "Install Android Studio? (y/N)") -match '^[yY]$') {
    Install-WingetPackage -Id 'Google.AndroidStudio' -DisplayName 'Android Studio' | Out-Null
}

Write-Host "----------------------------------------------" -ForegroundColor Gray
Write-Host "Workstation built." -ForegroundColor Cyan
Write-Host "Close this terminal and open a new one. Then run 'flutter doctor' to initialize the SDK." -ForegroundColor Yellow
