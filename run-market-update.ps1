param(
    [switch]$IgnoreScheduleWindow,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$monitorRoot = $PSScriptRoot
$envPath = Join-Path $monitorRoot '.env'
$baselinePath = Join-Path $monitorRoot 'baseline.json'
$currentPath = Join-Path $monitorRoot 'current.json'
$scraperPath = Join-Path $monitorRoot 'scrape-aldi.ps1'

function Import-DotEnv {
    param([string]$Path)
    $values = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
            $parts = $trimmed.Split('=', 2)
            if ($parts.Count -eq 2) { $values[$parts[0].Trim()] = $parts[1].Trim() }
        }
    }
    foreach ($key in @('GMAIL_USERNAME', 'GMAIL_APP_PASSWORD', 'EMAIL_RECIPIENT', 'EMAIL_SUBJECT')) {
        $environmentValue = [Environment]::GetEnvironmentVariable($key)
        if (-not [string]::IsNullOrWhiteSpace($environmentValue)) { $values[$key] = $environmentValue }
    }
    return $values
}

function Format-Value {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '(not displayed)' }
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-ProductKey {
    param($Product)
    return "$($Product.searchTerm)|$($Product.sku)"
}

if (-not $IgnoreScheduleWindow) {
    $aestNow = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTimeOffset]::UtcNow, 'E. Australia Standard Time')
    if ($aestNow.DayOfWeek -ne 'Wednesday' -or $aestNow.Hour -ne 8) { exit 0 }
}

$config = Import-DotEnv $envPath
foreach ($required in @('GMAIL_USERNAME', 'GMAIL_APP_PASSWORD', 'EMAIL_RECIPIENT', 'EMAIL_SUBJECT')) {
    if ([string]::IsNullOrWhiteSpace($config[$required])) { throw "Set $required in $envPath before running the update." }
}

if (-not (Test-Path -LiteralPath $baselinePath)) { throw "Missing baseline: $baselinePath" }
& $scraperPath -OutputPath $currentPath

$baseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json
$current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
$oldByKey = @{}
$newByKey = @{}
foreach ($product in $baseline.products) { $oldByKey[(Get-ProductKey $product)] = $product }
foreach ($product in $current.products) { $newByKey[(Get-ProductKey $product)] = $product }

$changesByTerm = [ordered]@{
    'Pasta Sauce' = [System.Collections.Generic.List[object]]::new()
    'Tomato Paste' = [System.Collections.Generic.List[object]]::new()
}

foreach ($key in $newByKey.Keys) {
    $new = $newByKey[$key]
    $old = $oldByKey[$key]
    if ($null -eq $old) {
        $changesByTerm[$new.searchTerm].Add([ordered]@{ type='New product'; product=$new; detail="New listing at $(Format-Value $new.price)" })
        continue
    }

    if ($old.name -ne $new.name) {
        $changesByTerm[$new.searchTerm].Add([ordered]@{ type='Product name / flavour'; product=$new; detail="$(Format-Value $old.name) &rarr; $(Format-Value $new.name)" })
    }
    if ($old.sellingSize -ne $new.sellingSize) {
        $changesByTerm[$new.searchTerm].Add([ordered]@{ type='Size'; product=$new; detail="$(Format-Value $old.sellingSize) &rarr; $(Format-Value $new.sellingSize)" })
    }
    if ($old.price -ne $new.price) {
        $changesByTerm[$new.searchTerm].Add([ordered]@{ type='Price'; product=$new; detail="$(Format-Value $old.price) &rarr; $(Format-Value $new.price)" })
    }
    if (($old.imageSha256 -and $new.imageSha256 -and $old.imageSha256 -ne $new.imageSha256) -or $old.imageUrl -ne $new.imageUrl) {
        $changesByTerm[$new.searchTerm].Add([ordered]@{ type='Image'; product=$new; detail='Product image changed' })
    }
}

$totalChanges = ($changesByTerm.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
if (-not $totalChanges) {
    Move-Item -LiteralPath $currentPath -Destination $baselinePath -Force
    Write-Output 'No changes detected; no email sent.'
    exit 0
}

$sections = foreach ($term in @('Pasta Sauce', 'Tomato Paste')) {
    $items = $changesByTerm[$term]
    if (-not $items.Count) { continue }
    $rows = foreach ($change in $items) {
        $product = $change.product
        $link = [Net.WebUtility]::HtmlEncode($product.productUrl)
        "<tr><td>$(Format-Value $change.type)</td><td><a href='$link'>$(Format-Value $product.name)</a><br><small>$(Format-Value $product.brand) | SKU $(Format-Value $product.sku)</small></td><td>$($change.detail)</td></tr>"
    }
    "<h2>$term</h2><table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse'><thead><tr><th>Change</th><th>Product</th><th>Details</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
}

$aestDate = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTimeOffset]::UtcNow, 'E. Australia Standard Time').ToString('dd MMMM yyyy')
$htmlBody = "<html><body><h1>$(Format-Value $config.EMAIL_SUBJECT)</h1><p>Verified ALDI Australia changes detected on $aestDate. Source: <a href='https://www.aldi.com.au/'>aldi.com.au</a>.</p>$($sections -join '')</body></html>"

if ($DryRun) {
    $previewPath = Join-Path $monitorRoot 'email-preview.html'
    Set-Content -LiteralPath $previewPath -Value $htmlBody -Encoding utf8
    Write-Output "Dry run: $totalChanges changes written to $previewPath"
    exit 0
}

$message = [Net.Mail.MailMessage]::new()
$smtp = [Net.Mail.SmtpClient]::new('smtp.gmail.com', 587)
try {
    $message.From = $config.GMAIL_USERNAME
    $message.To.Add($config.EMAIL_RECIPIENT)
    $message.Subject = $config.EMAIL_SUBJECT
    $message.Body = $htmlBody
    $message.IsBodyHtml = $true
    $smtp.EnableSsl = $true
    $smtp.Credentials = [Net.NetworkCredential]::new($config.GMAIL_USERNAME, $config.GMAIL_APP_PASSWORD.Replace(' ', ''))
    $smtp.Send($message)
}
finally {
    $message.Dispose()
    $smtp.Dispose()
}

Move-Item -LiteralPath $currentPath -Destination $baselinePath -Force
Write-Output "Sent $totalChanges verified changes to $($config.EMAIL_RECIPIENT)."

