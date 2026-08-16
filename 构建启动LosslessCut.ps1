<#
.SYNOPSIS
    自动构建并启动 lossless-cut（桌面版 LosslessCut）。

.DESCRIPTION
    原则：本脚本自身不自动下载任何依赖。LosslessCut 内部构建子过程
    （如 yarn install 触发的下载）允许自行执行；若子过程失败，本脚本尝试解决：
    能在本机找到的依赖就注入路径后重试（只注入路径，不复制依赖本身），
    并把注入记录到脚本同目录的“依赖注入状态.json”，
    以后运行直接沿用，不再走失败重试逻辑；找不到则报错给用户。

    执行流程：
      1. 定位 Node.js 与项目自带 Yarn 4 发行版；
      2. 安装依赖（放任 yarn 自带的下载逻辑；失败时注入本机能找到的依赖后重试一次，
         例如缺失的 esbuild 平台二进制）；
      3. 确定 ffmpeg / ffprobe：-FfmpegPath 参数 → 项目标准目录 → 状态记录 → PATH，
         非标准目录通过 customFfPath 启动参数注入，不复制文件；
      4. 保障 Electron 二进制：标准位置缺失时注入状态记录的 exe（ELECTRON_EXEC_PATH）；
      5. 执行构建（generate-icon + electron-vite build；同样支持失败注入重试）；
      6. 用第 4 步确定的 Electron 可执行文件直接启动应用（等价于
         electron-vite preview 的启动部分），非标准 ffmpeg 目录随
         --settings-json '{customFfPath:"目录"}' 启动参数注入。

.PARAMETER 项目根目录
    lossless-cut 源码目录路径。默认为脚本上一级目录下的 lossless-cut。

.PARAMETER 跳过安装
    跳过依赖安装步骤（依赖已经安装过时使用）。

.PARAMETER 跳过构建
    跳过构建步骤（已经构建过、只想启动时使用）。

.PARAMETER FfmpegPath
    可选。指定 ffmpeg.exe / ffprobe.exe 所在目录（非标准位置），
    应用将直接使用该目录，不做任何复制。不指定时按以下顺序自动查找：
      1. 项目标准位置 ffmpeg\win32-x64\lib\；
      2. 依赖注入状态中记录的目录（沿用，不再探测）；
      3. PATH 中的 ffmpeg / ffprobe（找到后记录）。
    全部找不到时脚本停止并向用户报错，不会自动下载安装。
    实现方式：启动时向应用传递自带的
    --settings-json '{customFfPath:"<目录>"}' 启动参数（见 docs/cli.md）。
#>

[CmdletBinding()]
param(
    [string]$项目根目录 = (Join-Path (Split-Path -Parent $PSScriptRoot) 'lossless-cut'),
    [switch]$跳过安装,
    [switch]$跳过构建,
    [string]$FfmpegPath
)

$ErrorActionPreference = 'Stop'

# ---------- 依赖注入状态（跨运行记忆，避免重复走失败重试逻辑） ----------
$依赖状态文件 = Join-Path $PSScriptRoot '依赖注入状态.json'

function 读取依赖状态 {
    if (Test-Path $依赖状态文件) {
        try {
            return (Get-Content $依赖状态文件 -Raw | ConvertFrom-Json)
        } catch {
            Write-Host "⚠ 依赖状态文件解析失败，按空状态处理: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    return $null
}

function 保存依赖状态 {
    param([Parameter(Mandatory)]$状态)
    $状态 | ConvertTo-Json | Set-Content -LiteralPath $依赖状态文件 -Encoding UTF8
    Write-Host "  依赖注入状态已记录: $依赖状态文件" -ForegroundColor DarkGray
}

function 记录依赖 {
    param([Parameter(Mandatory)][string]$名称, [Parameter(Mandatory)][string]$值)
    $现有属性 = $依赖状态.PSObject.Properties[$名称]
    if ($现有属性 -and $现有属性.Value -eq $值) { return }
    if ($现有属性) { $依赖状态.$名称 = $值 }
    else { $依赖状态 | Add-Member -NotePropertyName $名称 -NotePropertyValue $值 }
    保存依赖状态 $依赖状态
    Write-Host "  已记录依赖注入: $名称 = $值" -ForegroundColor DarkGray
}

$依赖状态 = 读取依赖状态
if ($null -eq $依赖状态) { $依赖状态 = [PSCustomObject]@{} }

# ---------- 本机可注入依赖的查找（供子过程失败重试时使用） ----------
function 查找Esbuild二进制 {
    # 优先状态记录，其次平台包目录，再其次 PATH（仅注入路径，不复制）
    if ($依赖状态.PSObject.Properties['EsbuildEXE'] -and (Test-Path $依赖状态.EsbuildEXE)) {
        return $依赖状态.EsbuildEXE
    }
    $平台包二进制 = Join-Path $项目根目录 'node_modules\@esbuild\win32-x64\esbuild.exe'
    if (Test-Path $平台包二进制) { return $平台包二进制 }
    $外部命令 = Get-Command esbuild -ErrorAction SilentlyContinue
    if ($外部命令) { return $外部命令.Source }
    return $null
}

function 尝试注入Esbuild {
    $二进制 = 查找Esbuild二进制
    if (-not $二进制) { return $false }
    $env:ESBUILD_BINARY_PATH = $二进制
    记录依赖 'EsbuildEXE' $二进制
    Write-Host "▶ 已注入 esbuild 二进制路径：$二进制" -ForegroundColor Cyan
    return $true
}

function 失败退出 {
    param([Parameter(Mandatory)][string]$信息)
    Write-Host ''
    Write-Host "❌ $信息" -ForegroundColor Red
    Write-Host '   请处理后重新运行本脚本。' -ForegroundColor Yellow
    exit 1
}

function 运行命令 {
    param(
        [Parameter(Mandatory)][string]$可执行文件,
        [Parameter(Mandatory)][string[]]$参数列表,
        [Parameter(Mandatory)][string]$步骤说明
    )
    Write-Host ''
    Write-Host "▶ $步骤说明" -ForegroundColor Cyan
    Write-Host "  命令: $可执行文件 $($参数列表 -join ' ')" -ForegroundColor DarkGray

    # 直接用进程方式运行并检查退出码，避免依赖 $LASTEXITCODE 在封装中的各种陷阱
    $进程 = Start-Process -FilePath $可执行文件 -ArgumentList $参数列表 -WorkingDirectory $项目根目录 -NoNewWindow -PassThru -Wait
    if ($进程.ExitCode -ne 0) {
        return $false
    }
    return $true
}

Write-Host '=== lossless-cut 自动构建启动脚本 ===' -ForegroundColor Green
Write-Host "项目根目录: $项目根目录"

# ---------- 1. 定位 Node.js ----------
$Node路径 = $null
if (Get-Command node -ErrorAction SilentlyContinue) {
    $Node路径 = (Get-Command node).Source
} else {
    $候选路径 = @(
        'C:\Program Files\Microsoft Visual Studio\18\Insiders\MSBuild\Microsoft\VisualStudio\NodeJs\node.exe'
    )
    foreach ($路径 in $候选路径) {
        if (Test-Path $路径) { $Node路径 = $路径; break }
    }
}
if (-not $Node路径) {
    失败退出 '未找到 Node.js。请安装 Node.js（建议 v22+）并加入 PATH 后重试。'
}
Write-Host "Node.js: $Node路径 ($(& $Node路径 --version))"

# ---------- 2. 定位项目内 Yarn 4 ----------
$Yarn入口 = Join-Path $项目根目录 '.yarn\releases\yarn-4.11.0.cjs'
if (-not (Test-Path $Yarn入口)) {
    失败退出 "未找到项目内置 Yarn 发行版: $Yarn入口，请确认 lossless-cut 源码完整（.yarn/releases 目录）。"
}
Write-Host "Yarn: $Yarn入口（项目内置 Yarn 4）"

# 按原则：先原样执行；失败后若本机能找到可注入的依赖则注入并仅重试一次。
# 状态文件中已记录的依赖会被预先注入，避免重复走失败重试逻辑。
function 带注入重试执行 {
    param(
        [Parameter(Mandatory)][string[]]$参数列表,
        [Parameter(Mandatory)][string]$步骤说明
    )
    # 预注入：上次运行已验证过可用的本机依赖，直接用，不再等失败
    $记录二进制 = $依赖状态.PSObject.Properties['EsbuildEXE']
    if ($记录二进制 -and (Test-Path $依赖状态.EsbuildEXE)) {
        $env:ESBUILD_BINARY_PATH = $依赖状态.EsbuildEXE
        Write-Host "▶ 预注入已记录的 esbuild 二进制：$($依赖状态.EsbuildEXE)" -ForegroundColor DarkGray
    }

    if (运行命令 $Node路径 (@($Yarn入口) + $参数列表) $步骤说明) { return }

    Write-Host ''
    Write-Host "⚠ $步骤说明 首次执行失败，尝试注入本机已找到的依赖后重试…" -ForegroundColor Yellow
    if (尝试注入Esbuild) {
        if (运行命令 $Node路径 (@($Yarn入口) + $参数列表) "$步骤说明（注入依赖后重试）") { return }
        失败退出 "$步骤说明 注入依赖后仍然失败，详情见上方输出。"
    }
    失败退出 "$步骤说明 失败，且本机没有可注入的依赖。详情见上方输出。"
}

# ---------- 3. 安装依赖 ----------
if ($跳过安装) {
    Write-Host ''
    Write-Host '▶ 已指定 -跳过安装，跳过依赖安装步骤。' -ForegroundColor Cyan
} else {
    带注入重试执行 @('install') '安装依赖（首次运行可能耗时较长）'
}
if (-not (Test-Path (Join-Path $项目根目录 'node_modules\electron'))) {
    失败退出 'node_modules\electron 不存在，依赖安装不完整，无法继续。（不会自动重试安装）'
}

# ---------- 4. ffmpeg / ffprobe ----------
# lossless-cut 默认从 ffmpeg\win32-x64\lib\ 查找 ffmpeg.exe / ffprobe.exe
#（见 src/main/ffmpeg.ts 的 getFfPath）；非标准目录通过应用自带的
# --settings-json '{customFfPath:"目录"}' 启动参数直接指定（见 docs/cli.md），不做复制。
$Ffmpeg标准目录 = Join-Path $项目根目录 'ffmpeg\win32-x64\lib'
$所需文件名列表 = @('ffmpeg.exe', 'ffprobe.exe')

function 检查Ffmpeg目录 {
    param([Parameter(Mandatory)][string]$目录)
    foreach ($名称 in $所需文件名列表) {
        if (-not (Test-Path (Join-Path $目录 $名称))) { return $false }
    }
    return $true
}

# 若目录里的 ffmpeg.exe 是符号链接（如 WinGet 的 Links 目录），解析到真实目录，
# 以保证运行时能连带加载同目录下的 dll。
function 解析符号链接目录 {
    param([Parameter(Mandatory)][string]$目录)
    $可执行文件信息 = Get-Item -LiteralPath (Join-Path $目录 'ffmpeg.exe')
    if ($可执行文件信息.LinkType -eq 'SymbolicLink') {
        return Split-Path -Parent (Get-Item -LiteralPath $可执行文件信息.Target).FullName
    }
    return $目录
}

$Ffmpeg使用目录 = $null

if ($FfmpegPath) {
    # 用户显式指定了非标准位置
    if (-not (检查Ffmpeg目录 $FfmpegPath)) {
        $缺少项 = $所需文件名列表 | Where-Object { -not (Test-Path (Join-Path $FfmpegPath $_)) }
        失败退出 ("指定的 FfmpegPath 目录（$FfmpegPath）中缺少: " + ($缺少项 -join '、') + '。')
    }
    $Ffmpeg使用目录 = $FfmpegPath
} elseif (检查Ffmpeg目录 $Ffmpeg标准目录) {
    $Ffmpeg使用目录 = $Ffmpeg标准目录
    Write-Host ''
    Write-Host "▶ ffmpeg/ffprobe 已就绪（项目标准目录）: $Ffmpeg标准目录" -ForegroundColor Cyan
} elseif ($依赖状态.PSObject.Properties['Ffmpeg目录'] -and (检查Ffmpeg目录 $依赖状态.Ffmpeg目录)) {
    # 沿用上次记录的注入结果，不再重新探测
    $Ffmpeg使用目录 = $依赖状态.Ffmpeg目录
    Write-Host ''
    Write-Host "▶ 沿用已记录的 ffmpeg 目录：$Ffmpeg使用目录" -ForegroundColor Cyan
} else {
    # 尝试在 PATH 中自动发现
    $ffmpeg命令 = Get-Command ffmpeg -ErrorAction SilentlyContinue
    $ffprobe命令 = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($ffmpeg命令 -and $ffprobe命令) {
        $ffmpeg目录 = 解析符号链接目录 (Split-Path -Parent $ffmpeg命令.Source)
        $ffprobe目录 = 解析符号链接目录 (Split-Path -Parent $ffprobe命令.Source)
        if ($ffmpeg目录 -ne $ffprobe目录) {
            失败退出 ("PATH 中 ffmpeg 与 ffprobe 解析后不在同一目录：$ffmpeg目录 与 $ffprobe目录，" +
                '为避免版本不一致问题，请用 -FfmpegPath 显式指定一个同时包含两者的目录。')
        }
        $Ffmpeg使用目录 = $ffmpeg目录
        Write-Host ''
        Write-Host "▶ 在 PATH 中发现 ffmpeg/ffprobe（解析符号链接后）: $Ffmpeg使用目录" -ForegroundColor Cyan
    } else {
        失败退出 'ffmpeg/ffprobe 在项目标准目录和 PATH 中均未找到。请用 -FfmpegPath 指定 ffmpeg.exe / ffprobe.exe 所在目录，或手动将两者放到 ffmpeg\win32-x64\lib\ 目录下。'
    }
}

$使用非标准Ffmpeg = ($Ffmpeg使用目录 -ne $Ffmpeg标准目录)
if ($使用非标准Ffmpeg) { 记录依赖 'Ffmpeg目录' $Ffmpeg使用目录 }

# ---------- 5. Electron 二进制 ----------
# electron-vite 的 preview 通过 node_modules\electron\path.txt 寻找 electron；
# 二进制缺失时会报 “Electron uninstall”。本脚本不下载；
# 能从本机找到可执行文件时通过 ELECTRON_EXEC_PATH 注入（electron-vite 直接支持该环境变量），不复制任何文件。
$Electron标准Exe = Join-Path $项目根目录 'node_modules\electron\dist\electron.exe'

if (Test-Path $Electron标准Exe) {
    # path.txt 是 electron-vite 定位标准位置二进制所需的元数据文件（一行文件名，非依赖本体）
    $pathTxt路径 = Join-Path $项目根目录 'node_modules\electron\path.txt'
    if (-not (Test-Path $pathTxt路径)) {
        Write-Host '▶ 补写缺失的 electron\path.txt（仅元数据）' -ForegroundColor Cyan
        'electron.exe' | Set-Content -LiteralPath $pathTxt路径 -NoNewline
    }
} else {
    Write-Host ''
    Write-Host '▶ 标准位置缺少 Electron 二进制，在本机查找可注入的可执行文件…' -ForegroundColor Cyan
    # 查找顺序：状态记录 → 用户已设置的 ELECTRON_EXEC_PATH 环境变量（仅注入路径，不复制）
    $Electron注入路径 = $null
    if ($依赖状态.PSObject.Properties['ElectronEXE'] -and (Test-Path $依赖状态.ElectronEXE)) {
        $Electron注入路径 = $依赖状态.ElectronEXE
    } elseif ($env:ELECTRON_EXEC_PATH -and (Test-Path $env:ELECTRON_EXEC_PATH)) {
        $Electron注入路径 = (Get-Item $env:ELECTRON_EXEC_PATH).FullName
    }

    if (-not $Electron注入路径) {
        $Electron版本 = (Get-Content (Join-Path $项目根目录 'node_modules\electron\package.json') -Raw | ConvertFrom-Json).version
        失败退出 ("Electron 二进制缺失（$Electron标准Exe），且本机没有可注入的可执行文件。" +
            "请从 https://github.com/electron/electron/releases 或国内镜像（如 https://npmmirror.com/mirrors/electron/）" +
            "下载 v$Electron版本 的 win32-x64 zip，把内容解压到 node_modules\electron\dist\（使该目录下直接包含 electron.exe）后重跑。本脚本不会自动下载。")
    }
    $env:ELECTRON_EXEC_PATH = $Electron注入路径
    记录依赖 'ElectronEXE' $Electron注入路径
    Write-Host "▶ 已注入 Electron 可执行文件：$Electron注入路径" -ForegroundColor Cyan
}

# ---------- 6. 构建 ----------
if ($跳过构建) {
    Write-Host ''
    Write-Host '▶ 已指定 -跳过构建，跳过构建步骤。（若从未构建过，preview 会因缺少 out 目录而失败）' -ForegroundColor Cyan
} else {
    带注入重试执行 @('build') '构建应用（generate-icon + electron-vite build）'
}

# ---------- 7. 启动 ----------
# 直接用第 5 步确定的 Electron 可执行文件启动应用（等价于 electron-vite preview 的
# 启动部分）。不走 `yarn start`/preview：其 cli.js 在 options['--'] 为空数组时
# 会用空数组覆写外部传入的 ELECTRON_CLI_ARGS 环境变量，导致参数无法透传。
# 非标准 ffmpeg 目录时随应用自带启动参数注入：
# --settings-json "{customFfPath:'<目录>'}"（见 docs/cli.md；JSON5 语法）。
# 注意：JSON5 字符串用单引号、路径用正斜杠（Windows 下 Node/Electron 同样接受），
# 以避开 Start-Process 对参数中双引号与反斜杠的转义破坏。
$启动参数串 = '.'
if ($使用非标准Ffmpeg) {
    $正斜杠路径 = $Ffmpeg使用目录 -replace '\\', '/'
    $设置Json = "{customFfPath:'" + $正斜杠路径 + "'}"
    # JSON5 字符串用单引号、路径用正斜杠，故可安全外包双引号；
    # 必须整体作为单个参数传递，否则路径中的空格会把参数拆断。
    $启动参数串 += ' --settings-json "' + $设置Json + '"'
    Write-Host ''
    Write-Host "▶ 使用非标准 ffmpeg 目录: $Ffmpeg使用目录" -ForegroundColor Cyan
    Write-Host "  启动参数: $启动参数串" -ForegroundColor DarkGray
}

$Electron启动Exe = $(if ($env:ELECTRON_EXEC_PATH) { $env:ELECTRON_EXEC_PATH } else { $Electron标准Exe })

# 启动输出重定向到临时日志，以便失败时分析原因；每次启动用独立日志文件。
$当前启动日志路径 = $null

function 执行启动 {
    param([int]$最长等待秒 = 20)
    $script:当前启动日志路径 = Join-Path $env:TEMP ('losslesscut-启动-' + (Get-Date -Format 'yyyyMMddHHmmss-ffff') + '.log')
    $进程 = Start-Process -FilePath $Electron启动Exe -ArgumentList $启动参数串 `
        -WorkingDirectory $项目根目录 -PassThru `
        -RedirectStandardOutput $当前启动日志路径 -RedirectStandardError ('{0}.err' -f $当前启动日志路径)
    [void]$进程.WaitForExit($最长等待秒 * 1000)
    return $进程
}

function 读取启动输出 {
    $输出 = ''
    foreach ($文件 in @($当前启动日志路径, ('{0}.err' -f $当前启动日志路径))) {
        if ($文件 -and (Test-Path $文件)) { $输出 += (Get-Content $文件 -Raw -ErrorAction SilentlyContinue) }
    }
    return $输出
}

Write-Host ''
Write-Host '▶ 启动 lossless-cut… 应用窗口弹出后即为启动成功。' -ForegroundColor Cyan
$启动进程 = 执行启动

if ($启动进程.HasExited) {
    $全部输出 = 读取启动输出
    Write-Host ''
    Write-Host '--- 启动失败，最后 30 行输出 ---' -ForegroundColor Yellow
    ($全部输出 -split [Environment]::NewLine | Where-Object { $_.Trim() } ) | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" }
    # 常见原因：已有实例在运行时，新实例会因单实例锁自动退出，请先关闭已打开的 LosslessCut。
    失败退出 "应用进程很快退出（退出码 $($启动进程.ExitCode)），启动失败。若已有实例在运行，请先关闭后重试。"
}

Write-Host ''
Write-Host "✅ 应用已启动（进程 ID $($启动进程.Id)）。如需停止，关闭应用窗口或结束该进程即可。" -ForegroundColor Green
if ($当前启动日志路径 -and (Test-Path $当前启动日志路径)) {
    Get-Content $当前启动日志路径 -Tail 6 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}
