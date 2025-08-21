param (
    [string]$Path,
    [switch]$FixPermissions
)

if (!(Test-Path $Path)) {
    Write-Host "❌ File not found: $Path" -ForegroundColor Red
    exit 1
}

$firstLine = Get-Content $Path -TotalCount 1
$isValidFormat = $false

switch -Regex ($firstLine) {
    "^-----BEGIN OPENSSH PRIVATE KEY-----" {
        Write-Host "✅ Valid OpenSSH private key." -ForegroundColor Green
        $isValidFormat = $true
    }
    "^PuTTY-User-Key-File" {
        Write-Host "❌ Incorrect format. This is a PuTTY private key (.ppk) file. You need to export it to OpenSSH format from PuTTYgen." -ForegroundColor Red
    }
    "^-----BEGIN RSA PRIVATE KEY-----" {
        Write-Host "⚠️ Legacy RSA PEM format detected. It might work, but converting to the modern OpenSSH format is recommended." -ForegroundColor Yellow
        $isValidFormat = $true
    }
    "^---- BEGIN SSH2 PUBLIC KEY ----" {
        Write-Host "❌ This is a public key, not a private key. You cannot use it for authentication." -ForegroundColor Red
    }
    default {
        Write-Host "❌ Unknown or unsupported key format. First line is: `"$firstLine`"" -ForegroundColor Red
    }
}

if ($isValidFormat) {
    try {
        $acl = Get-Acl $Path
        $hasWrite = $acl.Access | Where-Object { $_.FileSystemRights -match "Write" -and $_.IdentityReference -match $env:USERNAME }

        if ($FixPermissions) {
            if ($hasWrite) {
                try {
                    Write-Host "Attempting to fix permissions..." -ForegroundColor Cyan
                    icacls $Path /inheritance:r | Out-Null
                    icacls $Path /grant:r "$($env:USERNAME):R" | Out-Null
                    Write-Host "✅ Permissions fixed. The key is now read-only for your user." -ForegroundColor Green
                } catch {
                    Write-Host "❌ Failed to fix permissions. Error: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "✅ Permissions are already secure. No action needed." -ForegroundColor Green
            }
        } else {
            if ($hasWrite) {
                Write-Host "⚠️ Key file is writable by your user. Consider locking it down to read-only." -ForegroundColor Yellow
                Write-Host "   You can run this script again with the -FixPermissions flag to do this automatically."
            } else {
                Write-Host "✅ Key file permissions are secure (read-only)." -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "⚠️ Could not check file permissions. Error: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
