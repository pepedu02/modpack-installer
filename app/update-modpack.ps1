$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Net.Http

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDirectory 'updater-config.json'

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string] $property.Value)) {
        throw "The manifest is missing a non-empty '$Name' property."
    }

    return [string] $property.Value
}

function Get-JsonFromUri {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing
    }
    catch {
        throw "Could not download $Description from '$Uri'. $($_.Exception.Message)"
    }

    $content = if ($response.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($response.Content)
    }
    else {
        [string] $response.Content
    }

    if ($content -match '<!doctype html|<html') {
        throw "Google Drive returned an HTML page instead of $Description. Set the Drive file's General access to 'Anyone with the link' and keep the URL as a direct download URL."
    }

    try {
        return $content | ConvertFrom-Json
    }
    catch {
        throw "The downloaded $Description is not valid JSON. $($_.Exception.Message)"
    }
}

function Format-Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [long] $Bytes
    )

    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }
    if ($Bytes -ge 1MB) {
        return ('{0:N2} MB' -f ($Bytes / 1MB))
    }
    return ('{0:N2} KB' -f ($Bytes / 1KB))
}

function Download-FileWithProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    $client = New-Object System.Net.Http.HttpClient
    $response = $null
    $inputStream = $null
    $outputStream = $null

    try {
        $response = $client.GetAsync(
            $Uri,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $null = $response.EnsureSuccessStatusCode()

        $totalBytes = $response.Content.Headers.ContentLength
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [System.IO.File]::Create($Destination)
        $buffer = New-Object byte[] (1MB)
        $downloadedBytes = [long] 0
        $startTime = [DateTime]::UtcNow
        $lastUpdate = $startTime

        while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead
            $now = [DateTime]::UtcNow

            if (($now - $lastUpdate).TotalMilliseconds -ge 250) {
                $elapsedSeconds = ($now - $startTime).TotalSeconds
                $speed = if ($elapsedSeconds -gt 0) {
                    $downloadedBytes / $elapsedSeconds
                }
                else {
                    0
                }

                if ($null -ne $totalBytes -and $totalBytes -gt 0) {
                    $percent = [Math]::Min(100, ($downloadedBytes / $totalBytes) * 100)
                    $status = '{0} / {1} at {2}/s' -f `
                        (Format-Bytes $downloadedBytes), `
                        (Format-Bytes $totalBytes), `
                        (Format-Bytes ([long] $speed))
                    Write-Progress -Activity "Downloading $fileName" -Status $status -PercentComplete $percent
                }
                else {
                    $status = '{0} at {1}/s' -f `
                        (Format-Bytes $downloadedBytes), `
                        (Format-Bytes ([long] $speed))
                    Write-Progress -Activity "Downloading $fileName" -Status $status
                }

                $lastUpdate = $now
            }
        }

        Write-Progress -Activity "Downloading $fileName" -Completed
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $inputStream) {
            $inputStream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
        $client.Dispose()
    }
}

function Test-OfficialMinecraftLauncher {
    $launcherPaths = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Minecraft Launcher\MinecraftLauncher.exe'),
        (Join-Path $env:ProgramFiles 'Minecraft Launcher\MinecraftLauncher.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Minecraft Launcher\MinecraftLauncher.exe')
    )

    foreach ($launcherPath in $launcherPaths) {
        if ($launcherPath -and (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            return $true
        }
    }

    return $false
}

function Test-PremiumMinecraftAccount {
    param(
        [Parameter(Mandatory = $true)]
        [string] $MinecraftDirectory
    )

    $accountsPath = Join-Path $MinecraftDirectory 'launcher_accounts.json'
    if (-not (Test-Path -LiteralPath $accountsPath -PathType Leaf)) {
        return $false
    }

    try {
        $accountsData = Get-Content -LiteralPath $accountsPath -Raw | ConvertFrom-Json
        $activeAccountId = [string] $accountsData.activeAccountLocalId
        $account = $accountsData.accounts.$activeAccountId
        return $null -ne $account -and
            $account.legacy -eq $false -and
            $null -ne $account.minecraftProfile
    }
    catch {
        return $false
    }
}

function Confirm-DirectInstallPrerequisites {
    $answer = Read-Host 'Do you want to install the modpack directly into Minecraft? (Y/N)'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host 'The ZIP is ready in the download folder.'
        return
    }

    if (-not (Test-OfficialMinecraftLauncher)) {
        throw 'The official Minecraft Launcher was not found. Direct installation requires a premium Minecraft account and the official launcher.'
    }

    $minecraftDirectory = Join-Path $env:APPDATA '.minecraft'
    if (-not (Test-PremiumMinecraftAccount -MinecraftDirectory $minecraftDirectory)) {
        throw 'An active premium Minecraft account could not be confirmed in the official launcher. Sign in to the launcher before using direct installation.'
    }

    $launcherProcesses = Get-Process -Name 'MinecraftLauncher' -ErrorAction SilentlyContinue
    if ($null -ne $launcherProcesses) {
        throw 'Please close the official Minecraft Launcher before installing the modpack, then run the updater again.'
    }

    $versionsDirectory = Join-Path $minecraftDirectory 'versions'
    $requiredVersionDirectories = @(
        '1.20.1-forge-47.4.20',
        'forge-1.20.1-47.4.20'
    )
    $installedVersion = $null

    foreach ($versionDirectory in $requiredVersionDirectories) {
        $candidate = Join-Path $versionsDirectory $versionDirectory
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $installedVersion = $versionDirectory
            break
        }
    }

    if ($null -eq $installedVersion) {
        throw 'Required Minecraft Forge version 1.20.1 (47.4.20) was not found in the .minecraft\versions folder.'
    }

    return @{
        MinecraftDirectory = $minecraftDirectory
        InstalledVersion = $installedVersion
    }
}

function Install-Modpack {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ArchivePath,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [Parameter(Mandatory = $true)]
        [hashtable] $Prerequisites
    )

    $launcherProfilesPath = Join-Path $Prerequisites.MinecraftDirectory 'launcher_profiles.json'
    if (-not (Test-Path -LiteralPath $launcherProfilesPath -PathType Leaf)) {
        throw "Minecraft launcher profiles were not found at '$launcherProfilesPath'."
    }

    $profileData = Get-Content -LiteralPath $launcherProfilesPath -Raw | ConvertFrom-Json
    if ($null -eq $profileData.profiles) {
        throw 'The Minecraft launcher profile file does not contain a profiles object.'
    }

    $safeVersion = $Version.Trim()
    if ([string]::IsNullOrWhiteSpace($safeVersion) -or
        $safeVersion.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $safeVersion.Contains('.') -and ($safeVersion -eq '..')) {
        throw 'The manifest version cannot be used as a folder name.'
    }

    $modpackRoot = [Environment]::ExpandEnvironmentVariables($config.installRoot)
    $installChannel = Get-RequiredProperty -Object $manifest -Name 'channel'
    if ($installChannel -notmatch '^(release|beta)$') {
        throw "The manifest channel must be either 'release' or 'beta'."
    }

    $installDirectory = Join-Path $modpackRoot $installChannel
    $stagingDirectory = Join-Path $modpackRoot (".$installChannel.installing")
    New-Item -ItemType Directory -Path $modpackRoot -Force | Out-Null

    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $stagingDirectory)
    }
    catch {
        if (Test-Path -LiteralPath $stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
        }
        throw "Could not extract the modpack archive. $($_.Exception.Message)"
    }

    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    $managedDirectories = @(
        'mods',
        'config',
        'defaultconfigs',
        'kubejs',
        'datapacks',
        'scripts'
    )

    foreach ($directoryName in $managedDirectories) {
        $stagedDirectory = Join-Path $stagingDirectory $directoryName
        $installedDirectory = Join-Path $installDirectory $directoryName

        if (Test-Path -LiteralPath $installedDirectory) {
            Remove-Item -LiteralPath $installedDirectory -Recurse -Force
        }

        if (Test-Path -LiteralPath $stagedDirectory -PathType Container) {
            Move-Item -LiteralPath $stagedDirectory -Destination $installedDirectory
        }
    }

    Get-ChildItem -LiteralPath $stagingDirectory -Force -File |
        Where-Object { $_.Name -ne 'options.txt' } |
        Copy-Item -Destination $installDirectory -Force
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force

    $optionsPath = Join-Path $Prerequisites.MinecraftDirectory 'options.txt'
    $installedOptionsPath = Join-Path $installDirectory 'options.txt'
    if ((-not (Test-Path -LiteralPath $installedOptionsPath -PathType Leaf)) -and
        (Test-Path -LiteralPath $optionsPath -PathType Leaf)) {
        Copy-Item -LiteralPath $optionsPath -Destination $installedOptionsPath
        Write-Host 'Copied the existing Minecraft options into the modpack installation.'
    }

    $backupPath = "$launcherProfilesPath.backup"
    Copy-Item -LiteralPath $launcherProfilesPath -Destination $backupPath -Force

    $profileId = [Guid]::NewGuid().ToString('N')
    $profile = [ordered] @{
        created = [DateTime]::UtcNow.ToString('o')
        icon = 'Creeper_Head'
        lastUsed = [DateTime]::UtcNow.ToString('o')
        lastVersionId = $Prerequisites.InstalledVersion
        name = "Flan's Modpack"
        type = 'custom'
        gameDir = $installDirectory
        javaArgs = '-Xmx10G -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:G1NewSizePercent=20 -XX:G1ReservePercent=20 -XX:MaxGCPauseMillis=50 -XX:G1HeapRegionSize=32M'
    }

    $existingProfile = $profileData.profiles.PSObject.Properties |
        Where-Object { $_.Value.name -eq "Flan's Modpack" } |
        Select-Object -First 1
    if ($null -ne $existingProfile) {
        $profileId = $existingProfile.Name
    }

    $profileData.profiles | Add-Member -MemberType NoteProperty -Name $profileId -Value ([pscustomobject] $profile) -Force
    $temporaryProfilesPath = "$launcherProfilesPath.installing"
    $profileJson = $profileData | ConvertTo-Json -Depth 10
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporaryProfilesPath, $profileJson, $utf8WithoutBom)
    Move-Item -LiteralPath $temporaryProfilesPath -Destination $launcherProfilesPath -Force

    Write-Host "Flan's Modpack was installed to $installDirectory."
    Write-Host "The launcher profile 'Flan's Modpack' was created."
    Write-Host "A launcher profile backup was saved to $backupPath."
}

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Configuration file not found: $configPath"
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$manifestUrl = Get-RequiredProperty -Object $config -Name 'manifestUrl'
$cacheDirectory = Get-RequiredProperty -Object $config -Name 'cacheDirectory'
$installRoot = Get-RequiredProperty -Object $config -Name 'installRoot'

if (-not $manifestUrl.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "manifestUrl must use HTTPS."
}

$cacheDirectory = $cacheDirectory.Replace('%INSTALLER_DIRECTORY%', $scriptDirectory)
$cacheDirectory = [Environment]::ExpandEnvironmentVariables($cacheDirectory)
New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
$config.installRoot = [Environment]::ExpandEnvironmentVariables($installRoot)

$manifest = Get-JsonFromUri -Uri $manifestUrl -Description 'the modpack manifest'
$latestVersion = Get-RequiredProperty -Object $manifest -Name 'latestVersion'
$fileName = Get-RequiredProperty -Object $manifest -Name 'fileName'
$downloadUrl = Get-RequiredProperty -Object $manifest -Name 'downloadUrl'
$expectedHash = (Get-RequiredProperty -Object $manifest -Name 'sha256').Trim().ToUpperInvariant()

if (-not $downloadUrl.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "downloadUrl must use HTTPS."
}

if ($expectedHash -notmatch '^[A-F0-9]{64}$') {
    throw "The manifest sha256 must be a 64-character hexadecimal SHA-256 hash."
}

if ([System.IO.Path]::GetFileName($fileName) -ne $fileName -or
    $fileName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "The manifest fileName must be a plain file name without directory components."
}

$destinationPath = Join-Path $cacheDirectory $fileName
$temporaryPath = Join-Path $cacheDirectory "$fileName.download"

if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
    $localHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($localHash -eq $expectedHash) {
        Write-Host "Modpack $latestVersion is already downloaded."
        $prerequisites = Confirm-DirectInstallPrerequisites
        if ($null -ne $prerequisites) {
            Install-Modpack -ArchivePath $destinationPath -Version $latestVersion -Prerequisites $prerequisites
        }
        exit 0
    }

    Write-Host "The existing $fileName does not match the manifest hash."
}
else {
    Write-Host "Modpack $latestVersion is not downloaded."
}

if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
    Remove-Item -LiteralPath $temporaryPath -Force
}

Write-Host "Downloading $fileName..."
try {
    Download-FileWithProgress -Uri $downloadUrl -Destination $temporaryPath
}
catch {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
    throw "Could not download the modpack from '$downloadUrl'. $($_.Exception.Message)"
}

$downloadedHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($downloadedHash -ne $expectedHash) {
    Remove-Item -LiteralPath $temporaryPath -Force
    throw "Downloaded file failed SHA-256 verification. Expected $expectedHash but received $downloadedHash."
}

Move-Item -LiteralPath $temporaryPath -Destination $destinationPath -Force

Write-Host "Modpack $latestVersion downloaded and verified successfully."
$prerequisites = Confirm-DirectInstallPrerequisites
if ($null -ne $prerequisites) {
    Install-Modpack -ArchivePath $destinationPath -Version $latestVersion -Prerequisites $prerequisites
}
