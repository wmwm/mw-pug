# verify.ps1
# PowerShell script to verify Ruby environment and gem health

# Expected Ruby path
$rubyPath = "C:\Ruby32-x64\bin\ruby.exe"

# Check Ruby version
if (Test-Path $rubyPath) {
    $version = & $rubyPath -v
    Write-Host "?? Ruby version: $version"
} else {
    Write-Host "? Ruby not found at $rubyPath"
    exit 1
}

# Check RBS gem
try {
    & $rubyPath -rrbs -e "puts '? RBS loaded: ' + RBS::VERSION"
} catch {
    Write-Host "?? RBS gem missing or broken: $_"
}

# Check Ruby LSP gem
try {
    & $rubyPath -rruby_lsp -e "puts '? Ruby LSP loaded: ' + RubyLsp::VERSION"
} catch {
    Write-Host "?? Ruby LSP gem missing or broken: $_"
}

# Check GEM_PATH
Write-Host "`n?? GEM_PATH:"
& $rubyPath -S gem env | Select-String "GEM PATHS" -Context 0,5
