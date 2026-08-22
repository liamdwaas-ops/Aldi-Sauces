$ErrorActionPreference = 'Stop'
$monitorRoot = $PSScriptRoot
$envPath = Join-Path $monitorRoot '.env'
$baselinePath = Join-Path $monitorRoot 'baseline.json'

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
    foreach ($key in @('GMAIL_USERNAME', 'GMAIL_APP_PASSWORD', 'EMAIL_RECIPIENT')) {
        $environmentValue = [Environment]::GetEnvironmentVariable($key)
        if (-not [string]::IsNullOrWhiteSpace($environmentValue)) { $values[$key] = $environmentValue }
    }
    return $values
}

function Encode {
    param($Value)
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

$config = Import-DotEnv $envPath
foreach ($required in @('GMAIL_USERNAME', 'GMAIL_APP_PASSWORD', 'EMAIL_RECIPIENT')) {
    if ([string]::IsNullOrWhiteSpace($config[$required])) { throw "Set $required in $envPath before sending." }
}
$baseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json
$sections = foreach ($term in @('Pasta Sauce', 'Tomato Paste')) {
    $products = @($baseline.products | Where-Object searchTerm -eq $term | Sort-Object brand,name)
    $rows = foreach ($product in $products) {
        $url = Encode $product.productUrl
        "<tr><td>$(Encode $product.sku)</td><td>$(Encode $product.brand)</td><td><a href='$url'>$(Encode $product.name)</a></td><td>$(Encode $product.sellingSize)</td><td>$(Encode $product.price)</td></tr>"
    }
    "<h2>$term ($($products.Count) SKUs)</h2><table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse'><thead><tr><th>SKU</th><th>Brand</th><th>Product</th><th>Size</th><th>Price</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
}
$body = "<html><body><h1>Aldi Sauces Market Update - Baseline Test</h1><p>This test contains the current eligible Aldi Australia baseline of $(@($baseline.products).Count) SKUs.</p>$($sections -join '')</body></html>"
$message = [Net.Mail.MailMessage]::new()
$smtp = [Net.Mail.SmtpClient]::new('smtp.gmail.com', 587)
try {
    $message.From = $config.GMAIL_USERNAME
    $message.To.Add($config.EMAIL_RECIPIENT)
    $message.Subject = 'Aldi Sauces Market Update - Baseline Test'
    $message.Body = $body
    $message.IsBodyHtml = $true
    $smtp.EnableSsl = $true
    $smtp.Credentials = [Net.NetworkCredential]::new($config.GMAIL_USERNAME, $config.GMAIL_APP_PASSWORD.Replace(' ', ''))
    $smtp.Send($message)
}
finally {
    $message.Dispose()
    $smtp.Dispose()
}
Write-Output "Baseline test email sent to $($config.EMAIL_RECIPIENT)."

