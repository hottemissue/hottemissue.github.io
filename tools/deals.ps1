# 30분마다: 쿠팡 골드박스 + 카테고리 베스트(약 1,500개)를 가져와 가격을 기록하고,
# 최근 30일 최고가보다 많이 떨어졌거나 30일 최저가를 새로 찍은 상품을 찾아
# 카톡에 붙여넣을 글 페이지(kakao.html)를 만들어요.
#   .\tools\deals.ps1
param(
  [int]$GoldCount = 10,     # 골드박스에서 몇 개
  [int]$BestPerCat = 3,     # 카테고리마다 베스트 몇 개 보여줄지
  [int]$ScanLimit = 100,    # 카테고리마다 베스트 몇 개까지 가격을 기록할지
  [int]$MaxSupers = 20,     # 초특급 최대 몇 개
  [int]$MaxDrops = 20,      # 가격 급락 최대 몇 개
  [int]$MaxLows = 20,       # 최저가 갱신 최대 몇 개
  [int]$SuperPct = 50,      # 최고가보다 몇 % 이상 떨어지면 초특급(바로 긴급 알림)으로 볼지
  [int]$DropPct = 20,       # 최고가보다 몇 % 이상 떨어지면 급락으로 볼지
  [int]$Days = 30,          # 최근 며칠 기록과 비교할지
  [int]$MinDays = 3         # 최저가라고 말하려면 며칠치 기록이 있어야 하는지
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$api = Join-Path $PSScriptRoot "coupang.ps1"
$dataDir = Join-Path $root "data"
New-Item -ItemType Directory -Force $dataDir | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)

# 베스트를 볼 카테고리 (쿠팡 파트너스 카테고리 번호 = 이름)
$CATS = [ordered]@{
  "1012" = "식품"; "1014" = "생활용품"; "1013" = "주방용품"; "1016" = "가전디지털"; "1010" = "뷰티"
  "1015" = "홈인테리어"; "1011" = "출산/유아동"; "1024" = "헬스/건강식품"; "1029" = "반려동물"; "1017" = "스포츠/레저"
}
# 급락·최저가를 찾으려고 가격만 기록하는 카테고리 (위 카테고리 + 패션, 자동차, 도서, 완구, 문구, 유아동패션)
$SCAN = @($CATS.Keys) + @("1001", "1002", "1018", "1019", "1020", "1021", "1030")

function Read-Hash([string]$name) {
  $h = @{}
  $path = Join-Path $dataDir $name
  if (Test-Path $path) {
    $o = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
  }
  return $h
}
function Save-Json([string]$name, $obj) {
  [IO.File]::WriteAllText((Join-Path $dataDir $name), ($obj | ConvertTo-Json -Depth 6 -Compress), $utf8)
}
# 같은 상품번호라도 옵션(용량, 개수)마다 가격이 달라서, 옵션 번호까지 붙여서 구분해요.
function Get-ItemKey($p) {
  $v = [regex]::Match(([Uri]$p.productUrl).Query, 'vendorItemId=(\d+)').Groups[1].Value
  if ($v) { "$($p.productId)-$v" } else { [string]$p.productId }
}

$kst = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, "Korea Standard Time")
$today = $kst.ToString("yyyy-MM-dd")
$cutoff = $kst.AddDays(1 - $Days).ToString("yyyy-MM-dd")

# 1) 쿠팡에서 가져오기
$gold = & $api -Action goldbox | ConvertFrom-Json
$best = & $api -Action best -Items $SCAN -Limit $ScanLimit | ConvertFrom-Json

# 2) 가격 기록 (상품옵션 -> { 날짜: [그날 최저, 그날 최고] }, 최근 $Days일만 보관)
$prices = @{}
foreach ($kv in (Read-Hash "prices.json").GetEnumerator()) {
  $hist = @{}
  foreach ($d in $kv.Value.PSObject.Properties) { if ($d.Name -ge $cutoff) { $hist[$d.Name] = @([int]$d.Value[0], [int]$d.Value[1]) } }
  if ($hist.Count) { $prices[$kv.Key] = $hist }
}

# 기록과 비교해서 '급락'(최고가보다 $DropPct% 이상 낮음)과 '최저가 갱신'(지난 기록 최저가보다 낮음) 찾기
$seen = @{}; $signals = @()
foreach ($p in @($gold) + @($best)) {
  $id = Get-ItemKey $p
  $price = [int][double]$p.productPrice
  if ($price -le 0 -or $seen.ContainsKey($id)) { continue }
  $seen[$id] = $true
  if (-not $prices.ContainsKey($id)) { $prices[$id] = @{} }
  $hist = $prices[$id]

  $was = 0; $prevMin = [int]::MaxValue; $firstDay = $today; $pastDays = 0
  foreach ($e in $hist.GetEnumerator()) {
    if ($e.Value[1] -gt $was) { $was = $e.Value[1] }
    if ($e.Key -lt $firstDay) { $firstDay = $e.Key }
    if ($e.Key -lt $today) { $pastDays++; if ($e.Value[0] -lt $prevMin) { $prevMin = $e.Value[0] } }
  }
  $span = [int]([datetime]::ParseExact($today, "yyyy-MM-dd", $null) - [datetime]::ParseExact($firstDay, "yyyy-MM-dd", $null)).TotalDays + 1
  $pct = if ($was -gt $price) { [int][Math]::Floor(100 * ($was - $price) / $was) } else { 0 }
  $isLow = ($pastDays -ge $MinDays) -and ($price -lt $prevMin)
  if ($pct -ge $DropPct -or $isLow) {
    $signals += [pscustomobject]@{ p = $p; was = $was; pct = $pct; low = $isLow; prevMin = $(if ($isLow) { $prevMin } else { 0 }); span = $span }
  }

  if ($hist.ContainsKey($today)) { $t = $hist[$today]; $hist[$today] = @([Math]::Min($t[0], $price), [Math]::Max($t[1], $price)) }
  else { $hist[$today] = @($price, $price) }
}
Save-Json "prices.json" $prices

# 3) 올릴 상품 고르기 (같은 상품은 한 번만)
$sel = @(); $used = @{}
function Add-Pick($type, $p, $extra) {
  $id = [string]$p.productId
  if ($used.ContainsKey($id)) { return }
  $used[$id] = $true
  $entry = @{ type = $type; p = $p }
  foreach ($k in $extra.Keys) { $entry[$k] = $extra[$k] }
  $script:sel += $entry
}
function Signal-Extra($x) { @{ was = $x.was; pct = $x.pct; low = $x.low; prevMin = $x.prevMin; span = $x.span } }
foreach ($x in ($signals | Where-Object { $_.pct -ge $SuperPct } | Sort-Object pct -Descending | Select-Object -First $MaxSupers)) { Add-Pick "super" $x.p (Signal-Extra $x) }
foreach ($x in ($signals | Where-Object { $_.pct -ge $DropPct -and $_.pct -lt $SuperPct } | Sort-Object pct -Descending | Select-Object -First $MaxDrops)) { Add-Pick "drop" $x.p (Signal-Extra $x) }
foreach ($x in ($signals | Where-Object { $_.low -and $_.pct -lt $DropPct } | Sort-Object pct -Descending | Select-Object -First $MaxLows)) { Add-Pick "low" $x.p (Signal-Extra $x) }
foreach ($p in ($gold | Sort-Object @{ Expression = { -not $_.isRocket } }, rank | Select-Object -First $GoldCount)) { Add-Pick "gold" $p @{} }
foreach ($c in $CATS.Keys) {
  foreach ($p in ($best | Where-Object { [string]$_.categoryId -eq $c } | Sort-Object rank | Select-Object -First $BestPerCat)) { Add-Pick "best" $p @{ cat = $CATS[$c] } }
}

# 4) 짧은 파트너스 링크 (한 번 만든 링크는 data/links.json에 저장해 두고 다시 써요)
$links = Read-Hash "links.json"
$need = @{}
foreach ($s in $sel) {
  $id = Get-ItemKey $s.p
  if ($links.ContainsKey($id) -or $need.ContainsKey($id)) { continue }
  $qs = ([Uri]$s.p.productUrl).Query
  $item = [regex]::Match($qs, 'itemId=(\d+)').Groups[1].Value
  $vend = [regex]::Match($qs, 'vendorItemId=(\d+)').Groups[1].Value
  $need[$id] = "https://www.coupang.com/vp/products/$($s.p.productId)" + $(if ($item -and $vend) { "?itemId=$item&vendorItemId=$vend" } else { "" })
}
$ids = @($need.Keys)
for ($i = 0; $i -lt $ids.Count; $i += 10) {
  $chunk = @($ids[$i..([Math]::Min($i + 9, $ids.Count - 1))])
  try {
    $res = & $api -Action deeplink -Items @($chunk | ForEach-Object { $need[$_] }) | ConvertFrom-Json
    $byUrl = @{}
    foreach ($l in $res) { $byUrl[$l.original] = $l.link }
    foreach ($id in $chunk) { if ($byUrl[$need[$id]]) { $links[$id] = $byUrl[$need[$id]] } }
  } catch { Write-Warning "deeplink failed: $($_.Exception.Message)" }
}
foreach ($id in @($links.Keys)) { if (-not $prices.ContainsKey($id)) { $links.Remove($id) } }
Save-Json "links.json" $links

# 5) 지난번에 없던 딜은 '새로 들어온 딜'로 표시
$state = Read-Hash "state.json"
$firstRun = -not $state.ContainsKey("keys")
$prev = @{}
foreach ($k in @($state["keys"])) { if ($k) { $prev[[string]$k] = $true } }

$deals = foreach ($s in $sel) {
  $p = $s.p; $id = Get-ItemKey $p
  $key = "$($s.type):$id"
  $link = $links[$id]
  if (-not $link) { $link = $p.productUrl }
  [pscustomobject]@{
    key = $key; type = $s.type; name = $p.productName; price = [int][double]$p.productPrice
    image = $p.productImage; rocket = [bool]$p.isRocket; link = $link
    cat = $s.cat; rank = [int]$p.rank; was = $s.was; pct = $s.pct
    low = [bool]$s.low; prevMin = $s.prevMin; span = $s.span
    isNew = (-not $firstRun) -and (-not $prev.ContainsKey($key))
  }
}
$deals = @($deals)
Save-Json "state.json" @{ keys = @($deals | ForEach-Object { $_.key }) }

# 6) kakao.html 만들기
$data = [pscustomobject]@{
  updated = $kst.ToString("yyyy-MM-dd HH:mm"); days = $Days; dropPct = $DropPct; superPct = $SuperPct; minDays = $MinDays
  cats = @($CATS.Values); deals = $deals
} | ConvertTo-Json -Depth 5 -Compress
$tpl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "kakao.template.html"), [Text.Encoding]::UTF8)
$html = [regex]::Replace($tpl, '(?s)/\*DATA\*/.*?/\*END\*/', { param($m) "/*DATA*/$data/*END*/" })
[IO.File]::WriteAllText((Join-Path $root "kakao.html"), $html, $utf8)

# 7) 휴대폰 알림 내용 (보내는 건 tools/notify.ps1이 사이트가 새로 올라간 뒤에 해요)
#    - 새 초특급($SuperPct% 이상)은 시간 상관없이 '긴급' 알림으로 따로
#    - 새 급락, 새 최저가, 새 골드박스(3개 이상)는 보통 알림 하나로 묶어서
$notifyFile = Join-Path $env:TEMP "hottem-notify.json"
if (Test-Path $notifyFile) { Remove-Item $notifyFile }
$page = "https://hottemissue.github.io/kakao.html"
$line = { param($d) "-{0}% {1} {2:N0}원" -f $d.pct, $d.name, $d.price }
$newSupers = @($deals | Where-Object { $_.isNew -and $_.type -eq "super" } | Sort-Object pct -Descending)
$newDrops = @($deals | Where-Object { $_.isNew -and $_.type -eq "drop" } | Sort-Object pct -Descending)
$newLows = @($deals | Where-Object { $_.isNew -and $_.type -eq "low" })
$newGold = @($deals | Where-Object { $_.isNew -and $_.type -eq "gold" })
$notes = @()
if ($newSupers.Count) {
  $notes += [pscustomobject]@{
    title = "⚡ 초특급 최대 -$($newSupers[0].pct)% · $($newSupers.Count)개 떴어요"
    message = (@($newSupers | Select-Object -First 3 | ForEach-Object { & $line $_ })) -join "`n"
    click = $page; priority = 5; tags = @("rotating_light")
  }
}
if ($newDrops.Count -or $newLows.Count -or $newGold.Count -ge 3) {
  $parts = @()
  if ($newDrops.Count) { $parts += "📉 급락 $($newDrops.Count)개" }
  if ($newLows.Count) { $parts += "🏷️ 최저가 $($newLows.Count)개" }
  if ($newGold.Count) { $parts += "🔥 골드박스 $($newGold.Count)개" }
  $lines = @($newDrops | ForEach-Object { & $line $_ })
  $lines += @($newLows | ForEach-Object { "최저가 {0} {1:N0}원" -f $_.name, $_.price })
  if (-not $lines.Count) { $lines = @($newGold | ForEach-Object { "{0} {1:N0}원" -f $_.name, $_.price }) }
  $notes += [pscustomobject]@{
    title = ($parts -join " · ") + " 새로 올라왔어요"
    message = ($lines | Select-Object -First 3) -join "`n"
    click = $page
    priority = $(if (@($newDrops | Where-Object { $_.pct -ge 30 }).Count) { 4 } else { 3 })
    tags = @("shopping_cart")
  }
}
if ($notes.Count) { [IO.File]::WriteAllText($notifyFile, (ConvertTo-Json -InputObject @($notes) -Depth 4 -Compress), $utf8) }

$count = { param($t) @($deals | Where-Object { $_.type -eq $t }).Count }
"kakao.html: {0} deals (super {1}, drop {2}, low {3}, gold {4}, best {5}, new {6}) tracked {7} products, {8} KST" -f $deals.Count, (& $count "super"), (& $count "drop"), (& $count "low"), (& $count "gold"), (& $count "best"), @($deals | Where-Object { $_.isNew }).Count, $prices.Count, $kst.ToString("yyyy-MM-dd HH:mm")
