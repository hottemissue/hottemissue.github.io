# 매일 아침: 쿠팡 골드박스 특가를 가져와 카톡에 붙여넣을 글 페이지(kakao.html)를 만들어요.
#   .\tools\daily.ps1 -Max 10
param([int]$Max = 10)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$api = Join-Path $PSScriptRoot "coupang.ps1"

$gold = & $api -Action goldbox | ConvertFrom-Json
# 로켓배송 먼저, 그다음 쿠팡 순위대로
$picked = @($gold | Sort-Object @{ Expression = { -not $_.isRocket } }, rank | Select-Object -First $Max)

# 짧은 파트너스 링크(link.coupang.com/a/...)로 바꾸기
$urls = @($picked | ForEach-Object {
  $qs = ([Uri]$_.productUrl).Query
  $item = [regex]::Match($qs, 'itemId=(\d+)').Groups[1].Value
  $vend = [regex]::Match($qs, 'vendorItemId=(\d+)').Groups[1].Value
  "https://www.coupang.com/vp/products/$($_.productId)" + $(if ($item -and $vend) { "?itemId=$item&vendorItemId=$vend" } else { "" })
})
$map = @{}
if ($urls.Count) {
  $links = & $api -Action deeplink -Items $urls | ConvertFrom-Json
  foreach ($l in $links) { $map[$l.original] = $l.link }
}

$deals = for ($i = 0; $i -lt $picked.Count; $i++) {
  $p = $picked[$i]
  $link = $map[$urls[$i]]
  if (-not $link) { $link = $p.productUrl }
  [pscustomobject]@{
    name = $p.productName; price = [int][double]$p.productPrice; image = $p.productImage
    rocket = [bool]$p.isRocket; category = $p.categoryName; link = $link
  }
}

$kst = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, "Korea Standard Time")
$data = [pscustomobject]@{ updated = $kst.ToString("yyyy-MM-dd HH:mm"); deals = @($deals) } | ConvertTo-Json -Depth 4 -Compress

$tpl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "kakao.template.html"), [Text.Encoding]::UTF8)
$html = [regex]::Replace($tpl, '(?s)/\*DATA\*/.*?/\*END\*/', { param($m) "/*DATA*/$data/*END*/" })
[IO.File]::WriteAllText((Join-Path $root "kakao.html"), $html, (New-Object Text.UTF8Encoding($false)))
"kakao.html: $(@($deals).Count) deals ($($kst.ToString('yyyy-MM-dd HH:mm')) KST)"
