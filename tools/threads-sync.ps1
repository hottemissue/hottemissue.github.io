# 쓰레드에 올린 판매 글의 상품을 메인 페이지 목록에 번호를 붙여 넣어요 (threads-products.js).
# 비공개 저장소 threads-coupang-bot의 기록을 읽어서, GitHub Secrets의 THREADS_BOT_READ 토큰이 필요해요.
# 삭제한 글의 상품은 목록에서 빠지고, 한 번 받은 번호는 바뀌지 않아요.
#   .\tools\threads-sync.ps1
param(
  [string]$BotRepo = "hottemissue/threads-coupang-bot",
  [int]$FirstNo = 13        # 처음 쓸 번호 (1~12번은 직접 고른 상품)
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $env:THREADS_BOT_READ) { "THREADS_BOT_READ not set, skipping"; exit 0 }

$root = Split-Path $PSScriptRoot -Parent
$api = Join-Path $PSScriptRoot "coupang.ps1"
$outFile = Join-Path $root "threads-products.js"

function Get-BotJson([string]$path) {
  $res = Invoke-WebRequest "https://api.github.com/repos/$BotRepo/contents/$path" -UseBasicParsing -TimeoutSec 30 -Headers @{
    Authorization = "Bearer $($env:THREADS_BOT_READ.Trim())"; Accept = "application/vnd.github.raw"; "User-Agent" = "hottem-site"
  }
  [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray()) | ConvertFrom-Json
}

$posted = Get-BotJson "data/posted.json"
$prices = (Get-BotJson "data/prices.json").products

# 지금 살아 있는 판매 글의 상품 (같은 상품을 여러 번 올렸으면 한 번만)
$live = [ordered]@{}
foreach ($post in ($posted | Sort-Object time)) {
  $id = [regex]::Match([string]$post.product, 'products/(\d+)').Groups[1].Value
  if ($id -and -not $post.deleted) { $live[$id] = $post }
}

$before = if (Test-Path $outFile) { [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) } else { "" }
$saved = @{}
$m = [regex]::Match($before, '(?s)window\.THREADS_PRODUCTS = (\[.*\]);')
if ($m.Success) {
  $list = $m.Groups[1].Value | ConvertFrom-Json
  foreach ($x in $list) { $saved[[string]$x.product] = $x }
}
$nextNo = $FirstNo
foreach ($x in $saved.Values) { if ($x.no -ge $nextNo) { $nextNo = $x.no + 1 } }

$items = @()
foreach ($id in $live.Keys) {
  $info = $prices.$id
  $price = 0
  if ($info) { $price = [int](@($info.prices.PSObject.Properties | Sort-Object Name)[-1].Value) }

  if ($saved.ContainsKey($id)) {
    $item = $saved[$id]
    if ($price) { $item.price = $price }
    $items += $item
    continue
  }

  # 새 상품: 파트너스 링크를 못 만들면 다음 실행 때 다시 시도해요 (수수료 없는 링크는 올리지 않아요)
  try { $res = & $api -Action deeplink -Items @("https://www.coupang.com/vp/products/$id") | ConvertFrom-Json }
  catch { Write-Warning "deeplink failed for ${id}: $($_.Exception.Message)"; continue }
  $link = @($res)[0].link
  if (-not $link) { continue }

  $title = if ($info.name) { $info.name } else { [regex]::Match([string]$live[$id].title, "'(.+)'").Groups[1].Value }
  $items += [pscustomobject]@{
    no = $nextNo; title = $title; cat = "쓰레드"; emoji = "🧵"; img = ""; bg = "#f1f2f5"
    price = $price; rocket = [bool]$info.rocket; link = $link; photo = [string]$info.image; product = $id
  }
  $nextNo++
}

$items = @($items | Sort-Object no -Descending)
$json = ConvertTo-Json -InputObject $items -Depth 3 -Compress
$after = "/* tools/threads-sync.ps1이 자동으로 만드는 파일이에요. 직접 고치지 않아도 돼요. */`nwindow.THREADS_PRODUCTS = $json;`n"
if ($after -ne $before) { [IO.File]::WriteAllText($outFile, $after, (New-Object Text.UTF8Encoding($false))) }
"threads-products.js: $($items.Count) products, next number $nextNo"
