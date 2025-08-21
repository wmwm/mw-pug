$KeyPath = "c:\Users\timba\OneDrive\DevFolder\ruby-bot1.pem"
$RemoteUser = "ec2-user"
$RemoteHost = "3.107.188.143"

$RemoteCmd = @'
cd discord-bot && ruby bot.rb &
'@

ssh -i $KeyPath "$RemoteUser@$RemoteHost" $RemoteCmd

