param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'baseline.json')
)

$ErrorActionPreference = 'Stop'
$searchTerms = @('Pasta Sauce', 'Tomato Paste')
$allProducts = [System.Collections.Generic.List[object]]::new()
$retainedSkus = [System.Collections.Generic.HashSet[string]]::new()

function Get-Field {
    param([string]$Html, [string]$Pattern)
    $match = [regex]::Match($Html, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { return $null }
    return [Net.WebUtility]::HtmlDecode($match.Groups[1].Value).Trim()
}

function Get-ImageHash {
    param([string]$Url)
    if (-not $Url) { return $null }
    try {
        $bytes = (Invoke-WebRequest -UseBasicParsing $Url).Content
    }
    catch {
        return $null
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-CanonicalSearchTerm {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $hasPastaSauce = $Name -match '(?i)\bPasta\b' -and $Name -match '(?i)\bSauce\b'
    $hasTomatoPaste = $Name -match '(?i)\bTomato\b' -and $Name -match '(?i)\bPaste\b'
    $hasPassata = $Name -match '(?i)\bPassata\b'
    if ($hasTomatoPaste -or $hasPassata) { return 'Tomato Paste' }
    if ($hasPastaSauce) { return 'Pasta Sauce' }
    return $null
}

foreach ($searchTerm in $searchTerms) {
    $page = 1
    $seenSkus = [System.Collections.Generic.HashSet[string]]::new()

    while ($true) {
        $query = [uri]::EscapeDataString($searchTerm)
        $url = "https://www.aldi.com.au/results?q=$query&page=$page"
        $html = (Invoke-WebRequest -UseBasicParsing $url).Content
        $tiles = [regex]::Matches(
            $html,
            '<div id="product-tile-(?<sku>[^"]+)".*?(?=<div id="product-tile-|</main>)',
            [Text.RegularExpressions.RegexOptions]::Singleline
        )

        $newOnPage = 0
        foreach ($tile in $tiles) {
            $sku = $tile.Groups['sku'].Value
            if (-not $seenSkus.Add($sku)) { continue }
            $newOnPage++
            $tileHtml = $tile.Value
            $relativeUrl = Get-Field $tileHtml '<a href="([^"]+)" class="base-link product-tile__link'
            $imageUrl = Get-Field $tileHtml '<img class="base-image".*?src="([^"]+)"'
            $name = Get-Field $tileHtml 'data-test="product-tile__name".*?<p[^>]*>(.*?)</p>'
            $canonicalSearchTerm = Get-CanonicalSearchTerm $name
            if (-not $canonicalSearchTerm -or -not $retainedSkus.Add($sku)) { continue }

            $allProducts.Add([ordered]@{
                searchTerm = $canonicalSearchTerm
                sku        = $sku
                name       = $name
                brand      = Get-Field $tileHtml 'data-test="product-tile__brandname".*?<p[^>]*>(.*?)</p>'
                sellingSize = Get-Field $tileHtml 'data-test="product-tile__unit-of-measurement".*?<p>(.*?)</p>'
                price      = Get-Field $tileHtml 'base-price__regular"><span>(.*?)</span>'
                imageUrl   = $imageUrl
                imageSha256 = Get-ImageHash $imageUrl
                productUrl = if ($relativeUrl) { "https://www.aldi.com.au$relativeUrl" } else { $null }
            })
        }

        $hasNextPage = $html -match ('href="/results\?q=' + [regex]::Escape([uri]::EscapeDataString($searchTerm).Replace('%20', '+')) + '&amp;page=' + ($page + 1) + '"')
        if ($newOnPage -eq 0 -or -not $hasNextPage) { break }
        $page++
    }
}

$snapshot = [ordered]@{
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    source = 'https://www.aldi.com.au/'
    searches = $searchTerms
    products = $allProducts
}

$snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output "Captured $($allProducts.Count) Aldi search results in $OutputPath"

