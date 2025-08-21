# === CONFIGURATION ===
$KeyPath = "c:\Users\timba\OneDrive\DevFolder\ruby-bot1.pem"
$LocalZipPath = ".\bot.zip" # Relative path to the zip file in the project root
$RemoteUser = "ec2-user"
$RemoteHost = "3.107.188.143"
$RemoteHome = "/home/ec2-user"
$RemoteZipFile = "bot.zip"
$RemoteBotDir = "discord-bot"

# === REMOTE SCRIPT ===
# This script will be executed on the EC2 instance.
$RemoteScript = @"
#!/bin/bash
echo '[DIAGNOSTIC MODE]'

echo '--- Running yum update ---'
sudo yum update -y
echo "yum update exit code: $?"

echo '--- Running yum install ---'
sudo yum install -y ruby ruby-devel gcc make unzip procps sqlite-devel
echo "yum install exit code: $?"

echo '--- Running gem install bundler ---'
sudo gem install bundler
echo "gem install exit code: $?"

echo '--- Running pkill ---'
/usr/bin/pkill -f pugbot.rb
echo "pkill exit code: $? (Note: 1 means process not found, which is OK)"

echo '--- Running rm ---'
rm -rf $RemoteBotDir
echo "rm exit code: $?"

echo '--- Running unzip ---'
unzip -o $RemoteHome/$RemoteZipFile -d $RemoteBotDir
echo "unzip exit code: $?"

echo '--- Changing directory ---'
cd $RemoteBotDir
echo "cd exit code: $?"

if [ ! -f "Gemfile" ]; then
    echo "[ERROR] Gemfile not found after unzip!"
    exit 1
fi

echo '--- Running bundle install ---'
bundle install --path vendor/bundle
echo "bundle install exit code: $?"

if [ $? -ne 0 ]; then
    echo "[ERROR] bundle install failed."
    exit 1
fi

echo '--- Starting bot ---'
nohup bundle exec ruby bot/pugbot.rb > bot.log 2>&1 &
echo "nohup exit code: $?"

echo '[DIAGNOSTIC MODE] Script finished.'
"@

# === DEPLOYMENT STEPS ===

# 1. Create the bot archive
Write-Host "--- Step 1: Creating bot.zip archive ---" -ForegroundColor Cyan
$ArchiveFiles = @("bot", "Gemfile", "Gemfile.lock")
if (Test-Path $LocalZipPath) {
    Remove-Item $LocalZipPath
}
try {
    Compress-Archive -Path $ArchiveFiles -DestinationPath $LocalZipPath -ErrorAction Stop
    Write-Host "✅ Archive created." -ForegroundColor Green
} catch {
    Write-Host "❌ Archiving failed. Aborting." -ForegroundColor Red
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 2. Upload the bot archive
Write-Host "--- Step 2: Uploading bot.zip to EC2 ---" -ForegroundColor Cyan
scp -i $KeyPath $LocalZipPath "$($RemoteUser)@$($RemoteHost):$($RemoteHome)/$($RemoteZipFile)"
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ SCP upload failed. Aborting." -ForegroundColor Red
    exit 1
}
Write-Host "✅ Upload complete." -ForegroundColor Green

# 2. Execute the remote script
Write-Host "--- Step 2: Executing remote deployment script on EC2 ---" -ForegroundColor Cyan
ssh -i $KeyPath "$($RemoteUser)@$($RemoteHost)" $RemoteScript
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ SSH command failed." -ForegroundColor Red
    exit 1
}

Write-Host "✅ Deployment script executed successfully." -ForegroundColor Green
Write-Host "Bot should be running on the EC2 instance."

