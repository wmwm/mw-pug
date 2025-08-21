# PowerShell Bootstrap Script for Ruby LSP Environment

# --- Verification ---
Write-Host "Verifying Ruby installation..."
$ruby_version = ruby -v
if ($LASTEXITCODE -ne 0) {
    Write-Host "Ruby is not installed or not in PATH. Please install Ruby and try again."
    exit 1
}
Write-Host "Found Ruby: $ruby_version"

# --- Gem Installation ---
Write-Host "Installing required gems: bundler, rbs, ruby-lsp..."
gem install bundler rbs ruby-lsp
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to install one or more gems. Please check your Ruby environment."
    exit 1
}
Write-Host "Gems installed successfully."

# --- VS Code Configuration ---
Write-Host "Configuring VS Code settings..."
$settings_path = "$env:APPDATA\Code\User\settings.json"
if (-not (Test-Path $settings_path)) {
    New-Item -Path $settings_path -ItemType File -Value "{}"
}
$settings = Get-Content $settings_path -Raw | ConvertFrom-Json
$settings.'ruby.interpreter.commandPath' = 'C:\Ruby32-x64\bin\ruby.exe'
$settings | ConvertTo-Json | Set-Content $settings_path
Write-Host "VS Code settings updated."

# --- Final Sanity Check ---
Write-Host "Running final sanity check..."
$lsp_version = ruby -r ruby_lsp -e "puts RubyLsp::VERSION"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Ruby LSP sanity check failed."
    exit 1
}
Write-Host "Ruby LSP Version: $lsp_version"
Write-Host "Bootstrap complete!"
Write-Host ""
Write-Host "--- Next Steps ---"
Write-Host "1. Open VS Code."
Write-Host "2. Press Ctrl+Shift+P and type 'Ruby: Restart Language Server'."
Write-Host "3. Verify the output logs show Ruby 3.2.2 is activated."
