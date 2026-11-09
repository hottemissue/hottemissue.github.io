# GitHub 자동 실행에서 돌리는 스크립트예요. 예약 실행이 45~60분 간격으로 늦어져서,
# 한 번 실행될 때 안에서 10분 간격으로 여러 번 확인해요.
# 한 번 확인 = 딜 찾기 → 쓰레드 상품 넣기 → GitHub에 올리기 → 알림
#   .\tools\run-checks.ps1 -Checks 6
param(
  [int]$Checks = 6,          # 이번 실행에서 몇 번 확인할지
  [int]$EveryMinutes = 10,   # 몇 분 간격으로 확인할지
  [switch]$TestNotify        # 시험 알림 보내기
)

$ErrorActionPreference = "Stop"
$tools = $PSScriptRoot
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# 매번 확인을 시작할 때 GitHub에 있는 최신 상태로 맞춰요.
# (실행 두 개가 겹치거나 지난번 올리기가 충돌로 꼬였어도, 꼬인 파일을 버리고 깨끗하게 다시 시작해요)
function Sync-Main {
  if ((Test-Path .git\rebase-merge) -or (Test-Path .git\rebase-apply)) { git rebase --abort }
  git fetch -q origin main
  if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }
  git reset -q --hard origin/main
  if ($LASTEXITCODE -ne 0) { throw "git reset failed" }
}

function Publish-Changes {
  git add kakao.html data threads-products.js
  git diff --cached --quiet
  if ($LASTEXITCODE -eq 0) { return }
  git commit -q -m "Update deals"
  git pull --rebase -q
  if ($LASTEXITCODE -ne 0) {
    git rebase --abort
    throw "git pull failed (conflict with another run); next check starts fresh from main"
  }
  git push -q
  if ($LASTEXITCODE -ne 0) { throw "git push failed" }
  # 사이트는 push만으로 다시 빌드돼요 (따로 빌드 요청을 하면 두 번 빌드돼서 GitHub 한도에 걸려요)
}

$failed = 0
for ($i = 1; $i -le $Checks; $i++) {
  $start = Get-Date
  "=== check $i / $Checks ($($start.ToUniversalTime().ToString('HH:mm:ss')) UTC) ==="
  try {
    Sync-Main
    & "$tools\deals.ps1"
    # 쓰레드 동기화가 실패해도 딜 업데이트는 계속해요
    try { & "$tools\threads-sync.ps1" } catch { Write-Warning "threads sync failed: $($_.Exception.Message)" }
    Publish-Changes
    if ($TestNotify -and $i -eq 1) { & "$tools\notify.ps1" -Test } else { & "$tools\notify.ps1" }
  } catch {
    # 한 번 실패해도 다음 확인은 계속해요 (쿠팡 API가 잠깐 안 될 때가 있어요)
    $failed++
    Write-Warning "check $i failed: $($_.Exception.Message)"
  }
  $wait = $EveryMinutes * 60 - ((Get-Date) - $start).TotalSeconds
  if ($i -lt $Checks -and $wait -gt 0) { Start-Sleep -Seconds ([int]$wait) }
}

"finished: $($Checks - $failed) of $Checks checks succeeded"
if ($failed -eq $Checks) { exit 1 }
exit 0
