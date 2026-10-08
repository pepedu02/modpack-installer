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

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Configuration file not found: $configPath"
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$manifestUrl = Get-RequiredProperty -Object $config -Name 'manifestUrl'
$cacheDirectory = Get-RequiredProperty -Object $config -Name 'cacheDirectory'

if (-not $manifestUrl.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "manifestUrl must use HTTPS."
}

$cacheDirectory = $cacheDirectory.Replace('%INSTALLER_DIRECTORY%', $scriptDirectory)
$cacheDirectory = [Environment]::ExpandEnvironmentVariables($cacheDirectory)
New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null

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
