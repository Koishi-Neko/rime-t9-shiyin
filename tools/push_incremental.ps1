# 增量推送：只推主题/方案/lua 四个文件到手机 pinyin 目录
# 用法（手机已用数据线连接并解锁）：powershell -File tools\push_incremental.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

$shell = New-Object -ComObject Shell.Application
$phone = $shell.Namespace(17).Items() | Where-Object { $_.Name -like '*K80*' }
if (-not $phone) { Write-Output 'ERROR: 手机未连接'; exit 1 }
$storage = $phone.GetFolder.Items() | Where-Object { $_.Name -eq '内部存储设备' }
$py = $storage.GetFolder.Items() | Where-Object { $_.Name -eq 'pinyin' }
if (-not $py) { Write-Output 'ERROR: 未找到 pinyin 文件夹'; exit 1 }
$dest = $py.GetFolder

# 根目录文件
foreach ($f in @('theme\shiyin.trime.yaml', 'schema\t9.schema.yaml')) {
    $src = Join-Path $repo $f
    if (-not (Test-Path $src)) { Write-Output "ERROR: 缺 $src"; exit 1 }
    Write-Output ("推送: " + (Split-Path $src -Leaf))
    $dest.CopyHere($src, 0x614)
}

# lua 子目录
$luaDest = $dest.Items() | Where-Object { $_.Name -eq 'lua' }
if (-not $luaDest) { Write-Output 'ERROR: 手机端无 lua 文件夹'; exit 1 }
$luaDest = $luaDest.GetFolder
Get-ChildItem (Join-Path $repo 'lua') -Filter '*.lua' | ForEach-Object {
    Write-Output ("推送: lua/" + $_.Name)
    $luaDest.CopyHere($_.FullName, 0x614)
}

Start-Sleep -Seconds 5
$names = @($dest.Items() | ForEach-Object { $_.Name })
foreach ($n in @('shiyin.trime.yaml', 't9.schema.yaml')) {
    if ($names -contains $n) { Write-Output "确认: $n 已到位" } else { Write-Output "WARN: $n 未在手机端找到（可能仍在传输，稍等再查）" }
}
$luaNames = @($luaDest.Items() | ForEach-Object { $_.Name })
foreach ($n in @('t9_syllable.lua', 't9_syllable_core.lua', 't9_syllable_cycle.lua', 't9_syllable_filter.lua')) {
    if ($luaNames -contains $n) { Write-Output "确认: lua/$n 已到位" } else { Write-Output "WARN: lua/$n 未在手机端找到" }
}
Write-Output 'DONE'
