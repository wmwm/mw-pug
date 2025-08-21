# Git sync and prepare for next sprint

$changes = @(
    "qa/QA_RUNNER_README.md",
    "qa/qa_notification_runner.js",
    "qa/qa_notification_runner_cli.js",
    "config/qa_notification_test.yaml",
    "QA_TESTING_GUIDE.md",
    "QA_DEPLOYMENT_GUIDE.md",
    "QA_IMPLEMENTATION_SUMMARY.md"
)

Write-Host "Checking status of QA testing files..."
git status $changes

Write-Host "`nAdding files to Git..."
git add $changes

Write-Host "`nCommitting changes..."
git commit -m "Implement QA Testing System for v1.3.0 Notification Agent"

Write-Host "`nCreating branch for next sprint work..."
git checkout -b feature/qa-testing-enhancements

Write-Host "`nQA Testing implementation is complete and ready for next sprint!"
Write-Host "Run 'git push origin feature/qa-testing-enhancements' when ready to push to remote repository."
