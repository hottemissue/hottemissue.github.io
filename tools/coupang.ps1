# 쿠팡 파트너스 Open API 도우미. 키는 ../coupang-keys.json에서 읽어요 (GitHub에는 안 올라감).
#   상품 검색:     .\tools\coupang.ps1 -Action search -Items "감성 무드등" -Limit 5
#   파트너스 링크: .\tools\coupang.ps1 -Action deeplink -Items "https://www.coupang.com/vp/products/123", "..."
#   오늘의 골드박스: .\tools\coupang.ps1 -Action goldbox
#   카테고리 베스트: .\tools\coupang.ps1 -Action best -Items 1012, 1014 -Limit 20
param(
  [Parameter(Mandatory = $true)][ValidateSet("search", "deeplink", "goldbox", "best")][string]$Action,
  [string[]]$Items = @(),
  [int]$Limit = 5,
  [string]$SubId = "hottem"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# GitHub 자동 실행에서는 Secrets로 넣은 환경변수를, PC에서는 키 파일을 써요.
if ($env:COUPANG_ACCESS_KEY -and $env:COUPANG_SECRET_KEY) {
  $keys = [pscustomobject]@{ accessKey = $env:COUPANG_ACCESS_KEY.Trim(); secretKey = $env:COUPANG_SECRET_KEY.Trim() }
} else {
  $keyFile = Join-Path $PSScriptRoot "..\coupang-keys.json"
  $keys = Get-Content $keyFile -Raw -Encoding UTF8 | ConvertFrom-Json
}
if ($keys.accessKey -notmatch '^[\w-]+$' -or $keys.secretKey -notmatch '^[\w-]+$') {
  throw "coupang-keys.json에 Access Key와 Secret Key를 넣어주세요."
}

$base = "/v2/providers/affiliate_open_api/apis/openapi/v1"

function Invoke-Coupang([string]$Method, [string]$Path, [string]$Query = "", [string]$Body = "") {
  # 서명 규칙: HMAC-SHA256(secretKey, 서명시각 + 메서드 + 경로 + 쿼리)
  $date = [DateTime]::UtcNow.ToString("yyMMdd'T'HHmmss'Z'")
  $hmac = New-Object System.Security.Cryptography.HMACSHA256
  $hmac.Key = [Text.Encoding]::UTF8.GetBytes($keys.secretKey)
  $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($date + $Method + $Path + $Query))
  $sig = -join ($hash | ForEach-Object { $_.ToString("x2") })

  $uri = "https://api-gateway.coupang.com$Path"
  if ($Query) { $uri += "?$Query" }
  $req = @{
    Uri = $uri; Method = $Method; UseBasicParsing = $true; TimeoutSec = 20
    Headers = @{ Authorization = "CEA algorithm=HmacSHA256, access-key=$($keys.accessKey), signed-date=$date, signature=$sig" }
  }
  if ($Body) {
    $req.Body = [Text.Encoding]::UTF8.GetBytes($Body)
    $req.ContentType = "application/json;charset=UTF-8"
  }

  try {
    $res = Invoke-WebRequest @req
    return [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray()) | ConvertFrom-Json
  } catch {
    $resp = $_.Exception.Response
    if (-not $resp) { throw }
    $text = (New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd()
    throw "쿠팡 API 오류 $([int]$resp.StatusCode): $text"
  }
}

$out = switch ($Action) {
  "search" {
    foreach ($kw in $Items) {
      $q = "keyword=$([Uri]::EscapeDataString($kw))&limit=$Limit&subId=$SubId"
      $r = Invoke-Coupang "GET" "$base/products/search" $q
      [pscustomobject]@{
        keyword  = $kw
        products = @($r.data.productData | ForEach-Object {
          [pscustomobject]@{
            id = $_.productId; name = $_.productName; price = $_.productPrice
            image = $_.productImage; url = $_.productUrl; rocket = $_.isRocket
          }
        })
      }
    }
  }
  "deeplink" {
    $body = @{ coupangUrls = $Items; subId = $SubId } | ConvertTo-Json -Compress
    $r = Invoke-Coupang "POST" "$base/deeplink" "" $body
    $r.data | ForEach-Object { [pscustomobject]@{ original = $_.originalUrl; link = $_.shortenUrl } }
  }
  "goldbox" {
    $r = Invoke-Coupang "GET" "$base/products/goldbox" "subId=$SubId"
    $r.data
  }
  "best" {
    foreach ($cat in $Items) {
      $r = Invoke-Coupang "GET" "$base/products/bestcategories/$cat" "limit=$Limit&subId=$SubId"
      $r.data | ForEach-Object { $_ | Add-Member categoryId $cat -PassThru }
    }
  }
}
ConvertTo-Json @($out) -Depth 6
