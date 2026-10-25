<#
.SYNOPSIS
    安装 Godot 的 Windows 导出模板（只取需要的条目，不下载整个 1.28 GB 包）。

.DESCRIPTION
    由 build_release.bat --install-templates 调用，也可以单独运行。

    ## 为什么不直接把整个 .tpz 下载下来

    Godot 的 .tpz 里除了 Windows 模板，还塞着 Android 的整套东西：
      templates/android_debug.apk     约 120 MB
      templates/android_release.apk   约  99 MB
      templates/android_source.zip    约 204 MB
    这三项合计约 440 MB，而本项目只需要 Windows 的 4 个文件（约 200 MB）。
    实测本机到 GitHub 的速率只有约 90 KB/s，下完 1.28 GB 要数小时；
    只取 Windows 条目则快一个数量级，且失败代价小得多。

    ## 怎么做到只取一部分

    ZIP 的目录（central directory）在文件尾部，里面记录了每个条目
    local header 的绝对偏移。所以：
      1. Range 读最后 128 KB -> 找到 EOCD -> 拿到 central directory 位置
      2. Range 读 central directory -> 找到 windows_*_x86_64 的条目
      3. 只对这些条目的数据区间发 Range 请求，解压后落盘
    中间的 Android 大文件完全不碰。

    ## 为什么不顺序扫描

    最初的实现按 local header 逐条目前进，结果第 3 个条目就是
    android_source.zip，必须读完 444 MB 才能越过 —— 那就等于整包下载。
    必须走 central directory，才能直接跳到 Windows 条目。

    ## 为什么不用 Expand-Archive

    Expand-Archive 要求 .zip 扩展名（.tpz 会被拒），而且只能整包解压。
    这里用 System.IO.Compression.DeflateStream 只解自己抓下来的条目。

.PARAMETER Version
    模板目录名（点分），例如 4.7.2.stable。必须与引擎版本严格一致。

.PARAMETER Destination
    目标目录，通常是 %APPDATA%\Godot\export_templates\<Version>。

.PARAMETER All
    下载并安装所有平台的模板（慢，1.28 GB）。默认只取 Windows x86_64。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_templates.ps1 -Version 4.7.2.stable
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Destination = "",
    [switch]$All
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# "4.7.2.stable" -> GitHub release tag "4.7.2-stable"
# 目录名用点分，release tag 用连字符。写反任何一个是 404。
$parts = $Version.Split('.')
if ($parts.Count -lt 4) {
    throw "版本格式不对：$Version（应形如 4.7.2.stable）"
}
$releaseTag = ($parts[0..2] -join '.') + '-' + $parts[3]
$archiveName = "Godot_v$releaseTag" + "_export_templates.tpz"
$url = "https://github.com/godotengine/godot/releases/download/$releaseTag/$archiveName"

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path (Join-Path $env:APPDATA 'Godot\export_templates') $Version
}

Write-Host "[i] 版本 : $Version"
Write-Host "[i] Tag  : $releaseTag"
Write-Host "[i] 源   : $url"
Write-Host "[i] 目标 : $Destination"

if ($All) {
    Write-Host "[i] -All：下载完整模板包（约 1.28 GB）"
} else {
    Write-Host "[i] 只取 Windows 模板条目（跳过 Android 的约 440 MB）"
}

Add-Type -AssemblyName System.Net.Http

function New-HttpClient {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(2)
    return $client
}

function Get-RemoteSize {
    param($Client, [string]$Url)
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $Url)
    $resp = $Client.SendAsync($req).GetAwaiter().GetResult()
    $len = [long]$resp.Content.Headers.ContentLength
    $resp.Dispose()
    return $len
}

function Get-Range {
    param($Client, [string]$Url, [long]$Start, [long]$Length, [int]$Tries = 4)

    if ($Length -le 0) { return ,([byte[]]@()) }

    for ($k = 1; $k -le $Tries; $k++) {
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
            $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($Start, ($Start + $Length - 1))
            $resp = $Client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if ([int]$resp.StatusCode -ne 206) {
                throw ("expected 206, got " + [int]$resp.StatusCode)
            }
            $ms = New-Object System.IO.MemoryStream
            $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $stream.CopyTo($ms)
            $stream.Close(); $resp.Dispose()
            $buf = $ms.ToArray()
            $ms.Close()
            if ($buf.Length -ne $Length) {
                throw ("short read {0} != {1}" -f $buf.Length, $Length)
            }
            return ,$buf
        } catch {
            Write-Host ("    [!] 第 $k/$Tries 次失败：" + $_.Exception.Message)
            if ($k -eq $Tries) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

$client = New-HttpClient
$remoteSize = Get-RemoteSize -Client $client -Url $url
Write-Host ("[i] 远端大小 : {0:N0} 字节" -f $remoteSize)

if ($All) {
    $work = Join-Path $env:TEMP ("godot_tpl_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $archive = Join-Path $work $archiveName

    $have = 0
    $attempt = 0
    while ($have -lt $remoteSize) {
        $attempt++
        if ($attempt -gt 30) { throw "重试 30 次仍未完成" }
        Write-Host ("[i] 第 $attempt 次尝试，从 {0:N0} 字节继续" -f $have)
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
            if ($have -gt 0) {
                $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($have, $null)
            }
            $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $append = ($have -gt 0 -and $resp.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent)
            if (-not $append) { $have = 0 }
            $mode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $fs = New-Object System.IO.FileStream($archive, $mode, [System.IO.FileAccess]::Write)
            $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $buf = New-Object byte[] 2097152
            $last = Get-Date
            while ($true) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $fs.Write($buf, 0, $n)
                $have += $n
                if (((Get-Date) - $last).TotalSeconds -ge 15) {
                    Write-Host ("    {0:N0} / {1:N0} MB ({2:N1}%)" -f ($have/1MB), ($remoteSize/1MB), ($have/$remoteSize*100))
                    $last = Get-Date
                }
            }
            $fs.Flush(); $fs.Close(); $stream.Close(); $resp.Dispose()
        } catch {
            Write-Host ("[!] " + $_.Exception.Message)
            Start-Sleep -Seconds 5
        }
    }

    Write-Host "[i] 解压..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extract = Join-Path $work 'extract'
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $extract)
    $src = Join-Path $extract 'templates'
    if (-not (Test-Path $src)) { $src = $extract }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item (Join-Path $src '*') $Destination -Recurse -Force
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    $tailLen = [math]::Min(131072, $remoteSize)
    $tail = Get-Range -Client $client -Url $url -Start ($remoteSize - $tailLen) -Length $tailLen

    $eocdPos = -1
    for ($i = $tail.Length - 22; $i -ge 0; $i--) {
        if ($tail[$i] -eq 0x50 -and $tail[$i+1] -eq 0x4B -and $tail[$i+2] -eq 0x05 -and $tail[$i+3] -eq 0x06) {
            $eocdPos = $i
            break
        }
    }
    if ($eocdPos -lt 0) { throw "找不到 ZIP EOCD，模板包格式可能变了" }

    $nTotal   = [BitConverter]::ToUInt16($tail, $eocdPos + 10)
    $cdSize   = [BitConverter]::ToUInt32($tail, $eocdPos + 12)
    $cdOffset = [BitConverter]::ToUInt32($tail, $eocdPos + 16)
    Write-Host ("[i] ZIP 条目 {0} 个，central directory @ {1:N0}（{2:N0} 字节）" -f $nTotal, $cdOffset, $cdSize)

    $cd = Get-Range -Client $client -Url $url -Start $cdOffset -Length $cdSize

    $wanted = @()
    $i = 0
    while ($i + 46 -le $cd.Length) {
        if (-not ($cd[$i] -eq 0x50 -and $cd[$i+1] -eq 0x4B -and $cd[$i+2] -eq 0x01 -and $cd[$i+3] -eq 0x02)) { break }
        $method     = [BitConverter]::ToUInt16($cd, $i + 10)
        $compSize   = [BitConverter]::ToUInt32($cd, $i + 20)
        $uncompSize = [BitConverter]::ToUInt32($cd, $i + 24)
        $nameLen    = [BitConverter]::ToUInt16($cd, $i + 28)
        $extraLen   = [BitConverter]::ToUInt16($cd, $i + 30)
        $cmtLen     = [BitConverter]::ToUInt16($cd, $i + 32)
        $localOff   = [BitConverter]::ToUInt32($cd, $i + 42)
        $name = [System.Text.Encoding]::UTF8.GetString($cd, $i + 46, $nameLen)
        if ($name -like '*windows_*_x86_64*') {
            $wanted += [pscustomobject]@{ Name = $name; Method = $method; Comp = $compSize; Uncomp = $uncompSize; Local = $localOff }
        }
        $i += 46 + $nameLen + $extraLen + $cmtLen
    }

    if ($wanted.Count -eq 0) { throw "模板包里没有 windows_*_x86_64 条目" }
    $totalComp = ($wanted | Measure-Object -Property Comp -Sum).Sum
    Write-Host ("[i] 命中 {0} 个 Windows 条目，合计压缩 {1:N0} MB" -f $wanted.Count, ($totalComp / 1MB))

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    foreach ($e in $wanted) {
        Write-Host ("[i] 取 {0}（{1:N0} MB）" -f $e.Name, ($e.Comp / 1MB))
        $lh = Get-Range -Client $client -Url $url -Start $e.Local -Length 30
        $lnameLen  = [BitConverter]::ToUInt16($lh, 26)
        $lextraLen = [BitConverter]::ToUInt16($lh, 28)
        $dataStart = $e.Local + 30 + $lnameLen + $lextraLen

        $raw = Get-Range -Client $client -Url $url -Start $dataStart -Length $e.Comp

        if ($e.Method -eq 0) {
            $payload = $raw
        } else {
            $inMs = New-Object System.IO.MemoryStream(,$raw)
            $ds = New-Object System.IO.Compression.DeflateStream($inMs, [System.IO.Compression.CompressionMode]::Decompress)
            $outMs = New-Object System.IO.MemoryStream
            $ds.CopyTo($outMs)
            $ds.Close(); $inMs.Close()
            $payload = $outMs.ToArray()
            $outMs.Close()
        }

        if ($payload.Length -ne $e.Uncomp) {
            throw ("{0} 解压后 {1} 字节，应为 {2}" -f $e.Name, $payload.Length, $e.Uncomp)
        }

        $base = [System.IO.Path]::GetFileName($e.Name)
        $target = Join-Path $Destination $base
        [System.IO.File]::WriteAllBytes($target, $payload)
        Write-Host ("    -> {0}（{1:N0} 字节）" -f $target, $payload.Length)
    }
}

$client.Dispose()

$releaseTpl = Join-Path $Destination 'windows_release_x86_64.exe'
$debugTpl = Join-Path $Destination 'windows_debug_x86_64.exe'
Write-Host "[i] 校验："
Write-Host ("    windows_release_x86_64.exe 存在={0}" -f (Test-Path $releaseTpl))
Write-Host ("    windows_debug_x86_64.exe   存在={0}" -f (Test-Path $debugTpl))
if (-not (Test-Path $releaseTpl)) { throw "安装后仍找不到 $releaseTpl" }

Write-Host "[OK] 导出模板已安装到 $Destination"
