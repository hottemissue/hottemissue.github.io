# 매시간: 쿠팡 골드박스 + 카테고리 베스트를 가져와 가격을 기록하고,
# 최근 며칠보다 가격이 떨어진 상품을 찾아 카톡에 붙여넣을 글 페이지(kakao.html)를 만들어요.
#   .\tools\deals.ps1
param(
  [int]$GoldCount = 10,     # 골드박스에서 몇 개
  [int]$BestPerCat = 3,     # 카테고리마다 베스트 몇 개
  [int]$MaxDrops = 15,      # 가격 급락 최대 몇 개
  [int]$DropPct = 10,       # 최고가보다 몇 % 이상 떨어지면 급락으로 볼지
  [int]$Days = 7            # 최근 며칠 최고가와 비교할지
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
$best = & $api -Action best -Items @($CATS.Keys) -Limit 20 | ConvertFrom-Json

# 2) 가격 기록 (상품번호 -> { 날짜: [그날 최저, 그날 최고] }, 최근 $Days일만 보관)
$prices = @{}
foreach ($kv in (Read-Hash "prices.json").GetEnumerator()) {
  $hist = @{}
  foreach ($d in $kv.Value.PSObject.Properties) { if ($d.Name -ge $cutoff) { $hist[$d.Name] = @([int]$d.Value[0], [int]$d.Value[1]) } }
  if ($hist.Count) { $prices[$kv.Key] = $hist }
}

# 기록해 둔 최근 최고가보다 지금 가격이 많이 낮으면 '급락'
$seen = @{}; $drops = @()
foreach ($p in @($gold) + @($best)) {
  $id = Get-ItemKey $p
  $price = [int][double]$p.productPrice
  if ($price -le 0 -or $seen.ContainsKey($id)) { continue }
  $seen[$id] = $true
  if (-not $prices.ContainsKey($id)) { $prices[$id] = @{} }
  $hist = $prices[$id]

  $was = 0
  foreach ($v in $hist.Values) { if ($v[1] -gt $was) { $was = $v[1] } }
  if ($was -gt $price) {
    $pct = [int][Math]::Floor(100 * ($was - $price) / $was)
    if ($pct -ge $DropPct) { $drops += [pscustomobject]@{ p = $p; was = $was; pct = $pct } }
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
  $script:sel += @{ type = $type; p = $p; cat = $extra.cat; was = $extra.was; pct = $extra.pct }
}
foreach ($x in ($drops | Sort-Object pct -Descending | Select-Object -First $MaxDrops)) { Add-Pick "drop" $x.p @{ was = $x.was; pct = $x.pct } }
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
$first = -not $state.ContainsKey("keys")
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
    isNew = (-not $first) -and (-not $prev.ContainsKey($key))
  }
}
$deals = @($deals)
Save-Json "state.json" @{ keys = @($deals | ForEach-Object { $_.key }) }

# 6) kakao.html 만들기
$data = [pscustomobject]@{ updated = $kst.ToString("yyyy-MM-dd HH:mm"); days = $Days; cats = @($CATS.Values); deals = $deals } | ConvertTo-Json -Depth 5 -Compress
$tpl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "kakao.template.html"), [Text.Encoding]::UTF8)
$html = [regex]::Replace($tpl, '(?s)/\*DATA\*/.*?/\*END\*/', { param($m) "/*DATA*/$data/*END*/" })
[IO.File]::WriteAllText((Join-Path $root "kakao.html"), $html, $utf8)

$count = { param($t) @($deals | Where-Object { $_.type -eq $t }).Count }
"kakao.html: {0} deals (drop {1}, gold {2}, best {3}, new {4}) tracked {5} products, {6} KST" -f $deals.Count, (& $count "drop"), (& $count "gold"), (& $count "best"), @($deals | Where-Object { $_.isNew }).Count, $prices.Count, $kst.ToString("yyyy-MM-dd HH:mm")
