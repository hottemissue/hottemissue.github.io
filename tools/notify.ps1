# 새 딜 알림을 휴대폰(ntfy 앱)으로 보내요. deals.ps1이 만든 알림 파일이 있을 때만 보내요.
# 알림 채널 이름은 GitHub Secrets의 NTFY_TOPIC에 들어 있어요.
#   .\tools\notify.ps1          (자동 실행용)
#   .\tools\notify.ps1 -Test    (시험 알림 한 번 보내기)
param([switch]$Test)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $env:NTFY_TOPIC) { "NTFY_TOPIC not set, skipping"; exit 0 }

$file = Join-Path $env:TEMP "hottem-notify.json"
if ($Test) {
  $n = [pscustomobject]@{
    title = "🔔 핫템이슈 알림 연결 완료"
    message = "새 급락 딜이나 골드박스가 올라오면 이렇게 알려드릴게요. 누르면 카톡 글 페이지가 열려요."
    click = "https://hottemissue.github.io/kakao.html"; priority = 3; tags = @("tada")
  }
} elseif (Test-Path $file) {
  Start-Sleep -Seconds 60   # 사이트가 새로 올라갈 때까지 잠깐 기다렸다가 보내요
  $n = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json   # 알림 여러 개 (초특급 긴급 + 보통)
} else { "no new deals to notify"; exit 0 }

foreach ($x in @($n)) {
  $x | Add-Member topic $env:NTFY_TOPIC.Trim() -Force
  $body = [Text.Encoding]::UTF8.GetBytes(($x | ConvertTo-Json -Compress))
  Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/" -Body $body -ContentType "application/json; charset=utf-8" | Out-Null
  "notification sent: $($x.title)"
}
