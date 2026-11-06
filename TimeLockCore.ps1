#requires -Version 5.1
# =====================================================================
#  TimeLockCore.ps1 -- 时间锁核心逻辑
#  * AES-256-CBC 加密 + HMAC-SHA256 完整性校验（Encrypt-then-MAC）
#  * PBKDF2(300,000 次) 从口令派生密钥；免密模式用 DPAPI 包裹随机密钥
#  * 解锁时间写入头部并受 HMAC 保护，篡改时间会导致校验失败
#  * 时间判定只用网络时间（NTP / HTTPS Date），不信任本机时钟
# =====================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

if (-not $script:TlkAppDir) {
    if ($PSScriptRoot) { $script:TlkAppDir = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $script:TlkAppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { $script:TlkAppDir = (Get-Location).Path }
}
$script:TlkStatePath = Join-Path $script:TlkAppDir '.timelock-state.json'
$script:TlkLogPath   = Join-Path $script:TlkAppDir 'timelock.log'

$script:TlkMagic        = [byte[]](0x54, 0x4C, 0x4B, 0x31)   # "TLK1"
$script:TlkVersion      = 1
$script:TlkDefaultIters = 300000
$script:TlkMagicUtf8    = 'TLK1'

# ---------------------------------------------------------------------
#  BoundedReadStream：只允许读取文件中指定区间，避免把密文整段复制
# ---------------------------------------------------------------------
if (-not ('TimeLock.BoundedReadStream' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
namespace TimeLock {
    public sealed class BoundedReadStream : Stream {
        private readonly Stream inner;
        private long remaining;
        public BoundedReadStream(Stream innerStream, long start, long length) {
            if (innerStream == null) throw new ArgumentNullException("innerStream");
            inner = innerStream;
            inner.Position = start;
            remaining = length;
        }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position {
            get { throw new NotSupportedException(); }
            set { throw new NotSupportedException(); }
        }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) {
            if (remaining <= 0) return 0;
            int want = (int)Math.Min((long)count, remaining);
            int n = inner.Read(buffer, offset, want);
            remaining -= n;
            return n;
        }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        protected override void Dispose(bool disposing) {
            if (disposing) { inner.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
'@
}

# ---------------------------------------------------------------------
#  基础工具
# ---------------------------------------------------------------------
function New-RandomBytes {
    param([int]$Length)
    $b = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    , $b
}

function Test-BytesEqual {
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    return ($diff -eq 0)
}

function ConvertTo-UnixSeconds {
    param([datetime]$Time)
    $utc = $Time.ToUniversalTime()
    [long]([DateTimeOffset]$utc).ToUnixTimeSeconds()
}

function ConvertFrom-UnixSeconds {
    param([long]$Seconds)
    [DateTime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc).AddSeconds([double]$Seconds)
}

function Format-ByteSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [long]$Bytes)
}

function Format-Duration {
    param([timespan]$Span)
    if ($Span.TotalSeconds -le 0) { return '已到时间' }
    $d = [int][math]::Floor($Span.TotalDays)
    $h = $Span.Hours
    $m = $Span.Minutes
    if ($d -gt 0) { return ("{0} 天 {1} 小时 {2} 分" -f $d, $h, $m) }
    if ($h -gt 0) { return ("{0} 小时 {1} 分" -f $h, $m) }
    return ("{0} 分钟" -f [math]::Max(1, $m))
}

function Format-LocalTime {
    param([long]$UnixSeconds)
    (ConvertFrom-UnixSeconds $UnixSeconds).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
}

# ---------------------------------------------------------------------
#  日志与状态
# ---------------------------------------------------------------------
function Write-TlkLog {
    param([string]$Message)
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:TlkLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Read-TlkState {
    try {
        if (-not (Test-Path -LiteralPath $script:TlkStatePath)) { return $null }
        $raw = Get-Content -LiteralPath $script:TlkStatePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Save-TlkState {
    param([long]$NetUtc, [string[]]$Sources)
    try {
        $obj = [ordered]@{
            lastNetUtc   = $NetUtc
            lastNetLocal = (ConvertFrom-UnixSeconds $NetUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            lastLocalUtc = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            sources      = @($Sources)
        }
        $json = $obj | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($script:TlkStatePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------------------------------------------------------------
#  密钥与头部
# ---------------------------------------------------------------------
function Get-TlkKeys {
    param([string]$Password, [byte[]]$Salt, [int]$Iterations)
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $Salt, $Iterations)
    try { , $kdf.GetBytes(64) } finally { $kdf.Dispose() }
}

function New-TlkHeaderBytes {
    param(
        [byte]$Mode,
        [int]$Iterations,
        [byte[]]$Salt,
        [byte[]]$Iv,
        [byte[]]$Wrap,
        [string]$MetaJson
    )
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        $bw.Write($script:TlkMagic)
        $bw.Write([byte]$script:TlkVersion)
        $bw.Write([byte]$Mode)
        $bw.Write([int]$Iterations)
        $bw.Write($Salt, 0, 16)
        $bw.Write($Iv, 0, 16)
        $bw.Write([int]$Wrap.Length)
        $bw.Write($Wrap, 0, $Wrap.Length)
        $meta = [System.Text.Encoding]::UTF8.GetBytes($MetaJson)
        $bw.Write([int]$meta.Length)
        $bw.Write($meta, 0, $meta.Length)
        $bw.Flush()
        , $ms.ToArray()
    } finally { $bw.Dispose() }
}

function Read-TlkHeader {
    param([string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    $br = $null
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $magic = $br.ReadBytes(4)
        if ($magic.Length -ne 4 -or (Test-BytesEqual $magic $script:TlkMagic) -eq $false) {
            throw '不是有效的 .tlock 文件'
        }
        $ver = [int]$br.ReadByte()
        if ($ver -ne $script:TlkVersion) { throw "不支持的容器版本：$ver" }
        $mode = [int]$br.ReadByte()
        if ($mode -ne 0 -and $mode -ne 1) { throw '头部损坏（未知模式）' }
        $iter = [int]$br.ReadInt32()
        if ($iter -lt 0 -or $iter -gt 5000000) { throw '头部损坏（迭代次数）' }
        $salt = $br.ReadBytes(16)
        $iv = $br.ReadBytes(16)
        $wrapLen = [int]$br.ReadInt32()
        if ($wrapLen -lt 0 -or $wrapLen -gt 65536) { throw '头部损坏（密钥长度）' }
        $wrap = $br.ReadBytes($wrapLen)
        $metaLen = [int]$br.ReadInt32()
        if ($metaLen -lt 2 -or $metaLen -gt 1048576) { throw '头部损坏（元数据长度）' }
        $metaBytes = $br.ReadBytes($metaLen)
        $headerLen = [long](4 + 1 + 1 + 4 + 16 + 16 + 4 + $wrapLen + 4 + $metaLen)
        $meta = $null
        try { $meta = [System.Text.Encoding]::UTF8.GetString($metaBytes) | ConvertFrom-Json }
        catch { throw '头部损坏（元数据无法解析）' }
        return [pscustomobject]@{
            Version      = $ver
            Mode         = $mode
            Iterations   = $iter
            Salt         = $salt
            Iv           = $iv
            Wrap         = $wrap
            HeaderLength = $headerLen
            Meta         = $meta
            FileLength   = $fs.Length
        }
    } finally {
        if ($br) { $br.Dispose() }
        $fs.Dispose()
    }
}

function Get-TlkHmac {
    param([string]$Path, [byte[]]$Key, [long]$Length)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 1048576
        $left = [long]$Length
        while ($left -gt 0) {
            $want = [int][math]::Min([long]$buf.Length, $left)
            $n = $fs.Read($buf, 0, $want)
            if ($n -le 0) { throw '读取容器失败（文件可能被截断）' }
            [void]$hmac.TransformBlock($buf, 0, $n, $null, 0)
            $left -= $n
        }
        [void]$hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        , $hmac.Hash
    } finally {
        $fs.Dispose()
        $hmac.Dispose()
    }
}

function Get-TlkKeyMaterial {
    param($Header, [string]$Password)
    if ($Header.Mode -eq 0) {
        if ([string]::IsNullOrEmpty($Password)) { throw '该文件已设置密码，请输入密码' }
        $keys = Get-TlkKeys -Password $Password -Salt $Header.Salt -Iterations $Header.Iterations
    } elseif ($Header.Mode -eq 1) {
        try {
            $keys = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $Header.Wrap, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        } catch {
            throw '无法解开本机密钥：免密模式的容器只能在创建它的 Windows 账户 + 电脑上解锁'
        }
    } else {
        throw '未知的加密模式'
    }
    if ($null -eq $keys -or $keys.Length -ne 64) { throw '密钥材料长度异常' }
    $encKey = New-Object byte[] 32
    $macKey = New-Object byte[] 32
    [Array]::Copy($keys, 0, $encKey, 0, 32)
    [Array]::Copy($keys, 32, $macKey, 0, 32)
    return [pscustomobject]@{ EncKey = $encKey; MacKey = $macKey }
}

# ---------------------------------------------------------------------
#  收集要锁定的文件
# ---------------------------------------------------------------------
function Get-TlkFileList {
    param([string[]]$Paths)
    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $failed = New-Object 'System.Collections.Generic.List[string]'

    foreach ($raw in $Paths) {
        $item = Get-Item -LiteralPath $raw -Force -ErrorAction Stop
        if ($item -is [System.IO.DirectoryInfo]) {
            $children = Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }
            foreach ($c in $children) {
                if ($c.Extension -eq '.tlock') { continue }
                if ($seen.Add($c.FullName)) { $files.Add($c) }
            }
        } else {
            if ($item.Extension -eq '.tlock') { throw "不能锁定 .tlock 文件：$($item.FullName)" }
            if ($seen.Add($item.FullName)) { $files.Add($item) }
        }
    }
    return [pscustomobject]@{ Files = $files; Failed = $failed }
}

# ---------------------------------------------------------------------
#  锁定
# ---------------------------------------------------------------------
function Invoke-TlkLock {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][long]$UnlockUnix,
        [string]$Password = '',
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [switch]$KeepOriginals,
        [scriptblock]$OnProgress
    )

    if ($UnlockUnix -lt 946684800 -or $UnlockUnix -gt 4102444800) {
        throw '解锁时间超出合理范围（2000-2100 年）'
    }

    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    if ([System.IO.Path]::GetExtension($OutputPath) -ne '.tlock') {
        throw '输出文件必须使用 .tlock 扩展名'
    }
    $outDir = [System.IO.Path]::GetDirectoryName($OutputPath)
    if ($outDir -and -not [System.IO.Directory]::Exists($outDir)) {
        [void][System.IO.Directory]::CreateDirectory($outDir)
    }

    $list = Get-TlkFileList -Paths $Paths
    $files = $list.Files
    if ($files.Count -eq 0) { throw '没有可锁定的文件（文件夹可能为空）' }

    foreach ($f in $files) {
        if ([string]::Equals($f.FullName, $OutputPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "输出文件不能与要锁定的文件相同：$OutputPath"
        }
    }

    $totalBytes = [long]0
    foreach ($f in $files) { $totalBytes += $f.Length }

    $salt = New-RandomBytes 16
    $iv = New-RandomBytes 16

    $mode = 0
    $iterations = $script:TlkDefaultIters
    $wrap = New-Object byte[] 0
    if ([string]::IsNullOrEmpty($Password)) {
        $mode = 1
        $iterations = 0
        $keys = New-RandomBytes 64
        $wrap = [System.Security.Cryptography.ProtectedData]::Protect(
            $keys, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } else {
        $keys = Get-TlkKeys -Password $Password -Salt $salt -Iterations $iterations
    }

    $encKey = New-Object byte[] 32
    $macKey = New-Object byte[] 32
    [Array]::Copy($keys, 0, $encKey, 0, 32)
    [Array]::Copy($keys, 32, $macKey, 0, 32)

    $metaObj = [ordered]@{
        format     = $script:TlkMagicUtf8
        unlockUtc  = [long]$UnlockUnix
        unlockIso  = (ConvertFrom-UnixSeconds $UnlockUnix).ToString('yyyy-MM-ddTHH:mm:ssZ')
        createdUtc = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        createdIso = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        itemCount  = $files.Count
        totalBytes = $totalBytes
        host       = $env:COMPUTERNAME
        mode       = $(if ($mode -eq 0) { 'password' } else { 'dpapi' })
    }
    $metaJson = $metaObj | ConvertTo-Json -Compress
    $header = New-TlkHeaderBytes -Mode $mode -Iterations $iterations -Salt $salt -Iv $iv -Wrap $wrap -MetaJson $metaJson

    $created = $false
    try {
        $fsOut = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $created = $true
        $fsOut.Write($header, 0, $header.Length)
        $fsOut.Flush()

        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.BlockSize = 128
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $encKey
        $aes.IV = $iv
        $transform = $aes.CreateEncryptor()
        $cs = New-Object System.Security.Cryptography.CryptoStream($fsOut, $transform, [System.Security.Cryptography.CryptoStreamMode]::Write)
        $gz = New-Object System.IO.Compression.GZipStream($cs, [System.IO.Compression.CompressionMode]::Compress)
        $bw = New-Object System.IO.BinaryWriter($gz)

        try {
            $index = 0
            foreach ($f in $files) {
                $index++
                if ($OnProgress) {
                    try { & $OnProgress $index $files.Count $f.FullName } catch { }
                }
                $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($f.FullName)
                $bw.Write([int]$nameBytes.Length)
                $bw.Write($nameBytes, 0, $nameBytes.Length)
                $bw.Write([long]$f.Length)
                $bw.Flush()
                $in = [System.IO.File]::OpenRead($f.FullName)
                try { $in.CopyTo($gz) } finally { $in.Dispose() }
            }
            $bw.Write([int]-1)
            $bw.Flush()
        } finally {
            $bw.Dispose()
            $cs.Dispose()
            $transform.Dispose()
            $aes.Dispose()
        }

        $payloadLen = (New-Object System.IO.FileInfo($OutputPath)).Length
        $mac = Get-TlkHmac -Path $OutputPath -Key $macKey -Length $payloadLen
        $append = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
        try { $append.Write($mac, 0, 32) } finally { $append.Dispose() }

        $verify = Get-TlkHmac -Path $OutputPath -Key $macKey -Length $payloadLen
        if (-not (Test-BytesEqual $mac $verify)) { throw '写入后的完整性校验失败，已中止' }
    } catch {
        if ($created) {
            try { Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue } catch { }
        }
        throw
    }

    $deleted = 0
    $deleteFailures = New-Object 'System.Collections.Generic.List[string]'
    if (-not $KeepOriginals) {
        foreach ($f in $files) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $deleted++
            } catch {
                $deleteFailures.Add("$($f.FullName)：$($_.Exception.Message)")
            }
        }
    }

    Write-TlkLog ("LOCK ok  out=$OutputPath  files=$($files.Count)  bytes=$totalBytes  mode=$mode  unlock=$((ConvertFrom-UnixSeconds $UnlockUnix).ToString('u'))")

    return [pscustomobject]@{
        OutputPath     = $OutputPath
        FileCount      = $files.Count
        TotalBytes     = $totalBytes
        UnlockUnix     = [long]$UnlockUnix
        Mode           = $mode
        DeletedCount   = $deleted
        DeleteFailures = $deleteFailures
    }
}

# ---------------------------------------------------------------------
#  解锁（调用前必须已确认到达解锁时间）
# ---------------------------------------------------------------------
function Invoke-TlkUnlock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Password = '',
        [switch]$Overwrite,
        [switch]$DeleteContainer,
        [scriptblock]$OnProgress
    )

    $Path = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($Path)) { throw "文件不存在：$Path" }

    $hdr = Read-TlkHeader -Path $Path
    $fileLen = [long]$hdr.FileLength
    if ($fileLen -lt ($hdr.HeaderLength + 48)) { throw '容器不完整（文件被截断）' }

    # 核心层也强制时间校验：即使绕过了界面，也需要联网且到达解锁时间。
    $unlockUnix = [long]$hdr.Meta.unlockUtc
    $trusted = Get-TrustedUtc
    $left = (ConvertFrom-UnixSeconds $unlockUnix) - $trusted.Utc
    if ($left.TotalSeconds -gt 0) {
        throw ('还没到解锁时间，还剩 {0}。解锁时间：{1}' -f (Format-Duration $left), (Format-LocalTime $unlockUnix))
    }

    $keyMat = Get-TlkKeyMaterial -Header $hdr -Password $Password
    $macOffset = $fileLen - 32

    $storedMac = New-Object byte[] 32
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        [void]$fs.Seek($macOffset, [System.IO.SeekOrigin]::Begin)
        $read = 0
        while ($read -lt 32) {
            $n = $fs.Read($storedMac, $read, 32 - $read)
            if ($n -le 0) { throw '无法读取完整性校验值' }
            $read += $n
        }
    } finally { $fs.Dispose() }

    $calcMac = Get-TlkHmac -Path $Path -Key $keyMat.MacKey -Length $macOffset
    if (-not (Test-BytesEqual $storedMac $calcMac)) {
        throw '密码错误，或文件已损坏 / 被篡改'
    }

    $ctLen = $macOffset - $hdr.HeaderLength
    if ($ctLen -le 0) { throw '容器不完整（没有密文数据）' }

    $restored = New-Object 'System.Collections.Generic.List[string]'
    $skipped = New-Object 'System.Collections.Generic.List[string]'
    $restoreFailures = New-Object 'System.Collections.Generic.List[string]'
    $expected = 0
    try { $expected = [int]$hdr.Meta.itemCount } catch { $expected = 0 }

    $fs = [System.IO.File]::OpenRead($Path)
    $aes = $null
    $dec = $null
    $cs = $null
    $gz = $null
    $br = $null
    try {
        $bounded = New-Object TimeLock.BoundedReadStream($fs, [long]$hdr.HeaderLength, [long]$ctLen)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.BlockSize = 128
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $dec = $aes.CreateDecryptor($keyMat.EncKey, $hdr.Iv)
        $cs = New-Object System.Security.Cryptography.CryptoStream($bounded, $dec, [System.Security.Cryptography.CryptoStreamMode]::Read)
        $gz = New-Object System.IO.Compression.GZipStream($cs, [System.IO.Compression.CompressionMode]::Decompress)
        $br = New-Object System.IO.BinaryReader($gz)
        $buffer = New-Object byte[] 1048576

        $index = 0
        while ($true) {
            $pathLen = $br.ReadInt32()
            if ($pathLen -eq -1) { break }
            if ($pathLen -le 0 -or $pathLen -gt 32768) { throw '容器内容损坏（路径长度异常）' }
            $nameBytes = $br.ReadBytes($pathLen)
            if ($nameBytes.Length -ne $pathLen) { throw '容器内容损坏（路径被截断）' }
            $targetPath = [System.Text.Encoding]::UTF8.GetString($nameBytes)
            $size = $br.ReadInt64()
            if ($size -lt 0 -or $size -gt 1099511627776) { throw '容器内容损坏（文件大小异常）' }
            if (-not [System.IO.Path]::IsPathRooted($targetPath)) { throw "容器中的路径不是绝对路径：$targetPath" }

            $index++
            if ($OnProgress) {
                try { & $OnProgress $index $expected $targetPath } catch { }
            }

            $targetPath = [System.IO.Path]::GetFullPath($targetPath)
            $exists = [System.IO.File]::Exists($targetPath)
            if ($exists -and -not $Overwrite) {
                $skipped.Add($targetPath)
                $left = [long]$size
                while ($left -gt 0) {
                    $want = [int][math]::Min([long]$buffer.Length, $left)
                    $n = $gz.Read($buffer, 0, $want)
                    if ($n -le 0) { throw '容器内容损坏（数据被截断）' }
                    $left -= $n
                }
                continue
            }

            $dir = [System.IO.Path]::GetDirectoryName($targetPath)
            if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
                [void][System.IO.Directory]::CreateDirectory($dir)
            }

            $outFs = $null
            try {
                $outFs = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $left = [long]$size
                while ($left -gt 0) {
                    $want = [int][math]::Min([long]$buffer.Length, $left)
                    $n = $gz.Read($buffer, 0, $want)
                    if ($n -le 0) { throw '容器内容损坏（数据被截断）' }
                    $outFs.Write($buffer, 0, $n)
                    $left -= $n
                }
                $outFs.Flush()
            } catch {
                $restoreFailures.Add("$targetPath：$($_.Exception.Message)")
                throw
            } finally {
                if ($outFs) { $outFs.Dispose() }
            }
            $restored.Add($targetPath)
        }
    } catch {
        throw ("解锁失败：{0}（已恢复 {1} 个文件，可能有部分文件不完整）" -f $_.Exception.Message, $restored.Count)
    } finally {
        if ($br) { $br.Dispose() }
        if ($gz) { $gz.Dispose() }
        if ($cs) { $cs.Dispose() }
        if ($dec) { $dec.Dispose() }
        if ($aes) { $aes.Dispose() }
        $fs.Dispose()
    }

    if ($DeleteContainer) {
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        catch { $restoreFailures.Add("删除容器失败：$($_.Exception.Message)") }
    }

    Write-TlkLog ("UNLOCK ok  src=$Path  restored=$($restored.Count)  skipped=$($skipped.Count)")

    return [pscustomobject]@{
        Restored       = $restored
        Skipped        = $skipped
        Failures       = $restoreFailures
        Header         = $hdr
        ContainerPath  = $Path
    }
}

# ---------------------------------------------------------------------
#  网络时间（只信任网络时间，不使用本机时钟做判断）
# ---------------------------------------------------------------------
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Get-NtpTime {
    param([string]$Server, [int]$TimeoutMs = 2000)
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Server, 123)
        $request = New-Object byte[] 48
        $request[0] = 0x1B   # LI=0, VN=3, Mode=3 (client)
        [void]$udp.Send($request, 48)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref]$remote)
        if ($response.Length -lt 48) { throw 'NTP 响应过短' }
        if (($response[0] -band 0x07) -ne 4) { throw 'NTP 响应模式异常' }
        if ($response[1] -eq 0) { throw 'NTP 服务器返回 Kiss-o-Death' }
        $seconds = [double]$response[40] * 16777216 + [double]$response[41] * 65536 + [double]$response[42] * 256 + [double]$response[43]
        $fraction = ([double]$response[44] * 16777216 + [double]$response[45] * 65536 + [double]$response[46] * 256 + [double]$response[47]) / 4294967296.0
        $unix = $seconds - 2208988800.0 + $fraction
        $dt = (ConvertFrom-UnixSeconds ([long][math]::Floor($unix))).AddSeconds($unix - [math]::Floor($unix))
        if ($dt.Year -lt 2024 -or $dt.Year -gt 2100) { throw 'NTP 返回的时间不合理' }
        return $dt
    } finally {
        $udp.Dispose()
    }
}

function Get-HttpTime {
    param([string]$Url, [int]$TimeoutMs = 3500)

    $dateStr = $null
    foreach ($method in @('HEAD', 'GET')) {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = $method
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.UserAgent = 'TimeLock/1.0'
        $request.AllowAutoRedirect = $true
        $request.KeepAlive = $false
        $response = $null
        try {
            $response = $request.GetResponse()
            $dateStr = $response.Headers['Date']
            if (-not [string]::IsNullOrWhiteSpace($dateStr)) { break }
        } catch {
            if ($method -eq 'GET') { throw }
        } finally {
            if ($response) { $response.Close() }
        }
    }
    if ([string]::IsNullOrWhiteSpace($dateStr)) { throw '响应中没有 Date 头' }
    $dto = [DateTimeOffset]::Parse($dateStr, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal)
    $dt = $dto.UtcDateTime
    if ($dt.Year -lt 2024 -or $dt.Year -gt 2100) { throw '服务器返回的时间不合理' }
    return $dt
}

function Get-NetworkTime {
    param([switch]$IncludeDetail)

    $sources = New-Object 'System.Collections.Generic.List[object]'
    $errors = New-Object 'System.Collections.Generic.List[string]'

    foreach ($server in @('ntp.aliyun.com', 'cn.pool.ntp.org')) {
        if ($sources.Count -ge 2) { break }
        try {
            $t = Get-NtpTime -Server $server -TimeoutMs 2000
            $sources.Add([pscustomobject]@{ Source = "NTP $server"; Utc = $t })
        } catch {
            $errors.Add("NTP $server : $($_.Exception.Message)")
        }
    }

    if ($sources.Count -lt 2) {
        foreach ($url in @('https://www.baidu.com', 'https://www.microsoft.com', 'https://www.cloudflare.com')) {
            if ($sources.Count -ge 3) { break }
            try {
                $t = Get-HttpTime -Url $url -TimeoutMs 3500
                $sources.Add([pscustomobject]@{ Source = ("HTTPS " + ([uri]$url).Host); Utc = $t })
            } catch {
                $errors.Add("HTTPS $url : $($_.Exception.Message)")
            }
        }
    }

    if ($sources.Count -eq 0) {
        $detail = ($errors | Select-Object -First 3) -join ' | '
        throw ("无法获取网络时间，已拒绝执行。请检查网络/代理后重试。详情：$detail")
    }

    $sorted = @($sources | Sort-Object { $_.Utc })
    $min = $sorted[0].Utc
    $max = $sorted[$sorted.Count - 1].Utc
    $spread = [int][math]::Round(([timespan]($max - $min)).TotalSeconds)
    if ($spread -gt 600) {
        throw ("多个时间源结果不一致（相差 $spread 秒），已拒绝执行。请检查网络环境是否被劫持。")
    }
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)].Utc

    return [pscustomobject]@{
        Utc           = $median
        Local         = $median.ToLocalTime()
        SourceCount   = $sources.Count
        SpreadSeconds = $spread
        Sources       = $sorted
        Errors        = $errors
    }
}

function Get-TrustedUtc {
    param([switch]$IncludeDetail)
    $net = Get-NetworkTime -IncludeDetail:$IncludeDetail

    $state = Read-TlkState
    if ($state -and $null -ne $state.lastNetUtc) {
        $last = ConvertFrom-UnixSeconds ([long]$state.lastNetUtc)
        if ($net.Utc -lt $last.AddHours(-24)) {
            throw ("网络时间异常：本次 {0:yyyy-MM-dd HH:mm} UTC，比上次校验的 {1:yyyy-MM-dd HH:mm} UTC 早了 24 小时以上，已拒绝执行。请检查网络环境。" -f $net.Utc, $last)
        }
    }

    $sourceNames = @($net.Sources | ForEach-Object { $_.Source })
    Save-TlkState -NetUtc ([long](ConvertTo-UnixSeconds $net.Utc)) -Sources $sourceNames
    return $net
}
