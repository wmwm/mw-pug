# Dev Tools for Discord Bot Ruby Environment

## Scripts

### `cleanup.ps1`
- Disables Ruby 3.4.0 if present
- Clears Ruby LSP extension cache
- Verifies Ruby 3.2.2 is active
- Confirms RBS and Ruby LSP gems are installed

### `verify.ps1`
- Checks Ruby version at `C:\Ruby32-x64\bin\ruby.exe`
- Verifies `rbs` and `ruby_lsp` gems
- Prints current `GEM_PATH`

## Usage

Run from PowerShell in the bot root directory:

```powershell
.\dev-tools\cleanup.ps1
.\dev-tools\verify.ps1
```

## Notes

- Ruby 3.4.0 causes LSP crashes due to missing `rbs` gem and YJIT support
- Ensure `ruby.interpreter.commandPath` in VS Code points to Ruby 3.2.2
- Restart VS Code after running `cleanup.ps1`
