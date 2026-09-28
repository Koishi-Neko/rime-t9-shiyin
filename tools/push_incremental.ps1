# 增量推送：主题/方案/lua 六个文件 → 手机 pinyin 目录（Trime 部署导入的源文件夹）
# 用法（手机已用数据线连接并解锁）：powershell -File tools\push_incremental.ps1
#
# 机制说明（2026-09-28 实证）：
#   * Trime 3.3 点「部署」= 先从 SAF 源文件夹（本机 = pinyin/）导入覆盖 app 数据目录再编译，
#     所以只需推 pinyin/，不要直推 Android/data/...
#   * MTP CopyHere 对同名已存在文件可能静默跳过 → 本脚本先拉回比 sha256，不同就先删再推；
#     删除会弹系统确认框，需手动点「是」
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP 't9-push-verify'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$shell = New-Object -ComObject Shell.Application
$phone = $shell.Namespace(17).Items() | Where-Object { $_.Name -like '*K80*' }
if (-not $phone) { Write-Output 'ERROR: 手机未连接'; exit 1 }
$storage = $phone.GetFolder.Items() | Where-Object { $_.Name -eq '内部存储设备' }
$py = $storage.GetFolder.Items() | Where-Object { $_.Name -eq 'pinyin' }
if (-not $py) { Write-Output 'ERROR: 未找到 pinyin 文件夹'; exit 1 }
$pyDir = $py.GetFolder
$luaDir = ($pyDir.Items() | Where-Object { $_.Name -eq 'lua' }).GetFolder
if (-not $luaDir) { Write-Output 'ERROR: pinyin 下无 lua 目录'; exit 1 }

$targets = @(
    @{ rel = 'theme\shiyin.trime.yaml';    dir = $pyDir },
    @{ rel = 'schema\t9.schema.yaml';      dir = $pyDir },
    @{ rel = 'lua\t9_syllable.lua';        dir = $luaDir },
    @{ rel = 'lua\t9_syllable_core.lua';   dir = $luaDir },
    @{ rel = 'lua\t9_syllable_cycle.lua';  dir = $luaDir },
    @{ rel = 'lua\t9_syllable_filter.lua'; dir = $luaDir }
)
$failed = 0
foreach ($t in $targets) {
    $name = Split-Path $t.rel -Leaf
    $src = Join-Path $repo $t.rel
    if (-not (Test-Path $src)) { Write-Output "ERROR: 缺 $src"; $failed++; continue }
    $local = (Get-FileHash $src -Algorithm SHA256).Hash.ToLower()
    $dst = Join-Path $tmp $name
    if (Test-Path $dst) { Remove-Item $dst -Force }
    $f = $t.dir.Items() | Where-Object { $_.Name -eq $name }
    if ($f) {
        $shell.Namespace($tmp).CopyHere($f, 0x614)
        Start-Sleep -Seconds 3
        if ((Test-Path $dst) -and ((Get-FileHash $dst -Algorithm SHA256).Hash.ToLower() -eq $local)) {
            Write-Output "$name: 已是最新，跳过"; continue
        }
        Write-Output "$name: 旧版，删除重推（如弹确认框请点「是」）"
        ($f.Verbs() | Where-Object { $_.Name -match '删除|Delete' }).DoIt()
        Start-Sleep -Seconds 3
    } else {
        Write-Output "$name: 手机端缺失，直接推送"
    }
    $t.dir.CopyHere($src, 0x614)
    Start-Sleep -Seconds 5
    if (Test-Path $dst) { Remove-Item $dst -Force }
    $f2 = $t.dir.Items() | Where-Object { $_.Name -eq $name }
    if (-not $f2) { Write-Output "$name: WARN 推送后找不到"; $failed++; continue }
    $shell.Namespace($tmp).CopyHere($f2, 0x614)
    Start-Sleep -Seconds 3
    if ((Test-Path $dst) -and ((Get-FileHash $dst -Algorithm SHA256).Hash.ToLower() -eq $local)) {
        Write-Output "$name: 推送校验通过"
    } else { Write-Output "$name: WARN 推送后校验不过"; $failed++ }
}
if ($failed -gt 0) { Write-Output "DONE（$failed 个失败）"; exit 1 }
Write-Output 'DONE：全部一致。手机上打开同文·拾音点顶栏循环箭头「部署」后生效'
