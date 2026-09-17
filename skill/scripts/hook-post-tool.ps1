#Requires -Version 5.1
<#
.SYNOPSIS
    skill-audit 的 PostToolUse 钩子入口 —— 技能被修改或从 dsh 仓库恢复后，自动执行技能审核。

.DESCRIPTION
    dsh 通过 @deepseek-ai/dsh-hooks-claude-code 桥接把工具调用后的 payload 写到本脚本 stdin：
        { hook_event_name, tool_name, tool_input, tool_response, cwd, session_id, ... }
    审核范围判定：
        · write / edit 等文件工具 —— 目标路径落在 <DSH_HOME>\skills\<技能>\ 下 → 只审该技能
        · dsh_config_git_backup —— restore（仓库→活跃源，整批覆盖）与 backup（入库前）→ 全量
        · pwsh / bash 等 shell 工具 —— 命令行同时命中 skills 与写操作动词时才全量审核
          （shell 里改了哪个文件无法精确判定，宁可全量也不能漏）
        · 其它工具或无关路径 —— 静默退出，不产生任何输出

    审核发现 fail/warn 时，把摘要以 PostToolUse 的 additionalContext 回传给模型（模型会
    看到「技能审核未通过」并据此修复）；全部通过则保持安静，只在
    <DSH_HOME>\vet\skill-audits\ 留日志。

    退出码：始终 0（不阻塞工具调用）。审核失败通过上下文告知模型，而不是把工具调用判失败——
    文件已经写入，阻塞只会制造「写了却被拒」的困惑。

.NOTES
    本脚本是钩子：必须容忍垃圾输入（任何异常都静默退出），绝不因自身问题影响会话。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# 钩子 payload 与输出都是 UTF-8：显式设置，否则 5.1 在中文环境下按 GBK 读写会乱码。
try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Get-DshHome {
    if ($env:DSH_HOME) { return $env:DSH_HOME }
    return (Join-Path $env:USERPROFILE '.dsh')
}

function Write-HookContext {
    param([string]$Text)
    $payload = [pscustomobject]@{
        hookSpecificOutput = [pscustomobject]@{
            hookEventName     = 'PostToolUse'   # 必须精确匹配，否则协议丢弃事件作用域字段
            additionalContext = $Text
        }
    }
    # -Compress：多行 JSON 可能被执行器按行切分
    Write-Output ($payload | ConvertTo-Json -Depth 6 -Compress)
}

function Get-AllSkillNames {
    param([string]$SkillsRoot)
    return @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } |
        Select-Object -ExpandProperty Name)
}

# 从 tool_input 里尽力提取被操作的路径（不同工具键名不同，另有兜底扫描）。
function Get-CandidatePaths {
    param($ToolInput)
    $paths = New-Object System.Collections.ArrayList
    if ($null -eq $ToolInput) { return @() }
    foreach ($k in @('file_path', 'filePath', 'path', 'target_file', 'file', 'notebook_path')) {
        $prop = $ToolInput.PSObject.Properties | Where-Object { $_.Name -eq $k }
        if ($prop -and $prop.Value -is [string] -and $prop.Value) { [void]$paths.Add($prop.Value) }
    }
    # 兜底：任何字符串值里出现 skills\ 或 skills/ 的，也当候选路径
    foreach ($prop in $ToolInput.PSObject.Properties) {
        if ($prop.Value -is [string] -and $prop.Value -match 'skills[\\/]') { [void]$paths.Add($prop.Value) }
        elseif ($prop.Value -is [array]) {
            foreach ($v in $prop.Value) {
                if ($v -is [string] -and $v -match 'skills[\\/]') { [void]$paths.Add($v) }
            }
        }
    }
    return @($paths | Sort-Object -Unique)
}

# —— 1) 读 payload ——
$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch { }
if (-not $raw -or -not $raw.Trim()) { exit 0 }
$payload = $null
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }
if (-not $payload) { exit 0 }

$toolName = [string]$payload.tool_name
$toolInput = $payload.tool_input
if (-not $toolName) { exit 0 }

# 排障开关：存在 <TEMP>\finmeta2026\skill-audit-trace.on 时记录每次触发（默认关闭、零开销）。
# 用来回答「钩子到底被调用了没有」——它是判定钩子链路 HTTP 的第一手证据。
$traceSwitch = Join-Path $env:TEMP 'finmeta2026\skill-audit-trace.on'
if (Test-Path -LiteralPath $traceSwitch) {
    try {
        Add-Content -LiteralPath (Join-Path $env:TEMP 'finmeta2026\skill-audit-trace.log') -Encoding UTF8 `
            -Value ("{0}  tool={1}  rawLen={2}  cwd={3}" -f (Get-Date).ToString('HH:mm:ss'), $toolName, $raw.Length, [string]$payload.cwd)
    }
    catch { }
}

$skillsRoot = Join-Path (Get-DshHome) 'skills'
$auditScript = Join-Path $PSScriptRoot 'audit-skills.ps1'
if (-not (Test-Path -LiteralPath $auditScript)) { exit 0 }
if (-not (Test-Path -LiteralPath $skillsRoot)) { exit 0 }

# —— 2) 决定审核范围 ——
$targetSkills = New-Object System.Collections.ArrayList
$scope = ''

if ($toolName -eq 'dsh_config_git_backup') {
    $mode = ''
    if ($toolInput) {
        $modeProp = $toolInput.PSObject.Properties | Where-Object { $_.Name -eq 'mode' }
        if ($modeProp) { $mode = [string]$modeProp.Value }
    }
    if ($mode -and $mode.ToLower() -ne 'restore' -and $mode.ToLower() -ne 'backup') { exit 0 }
    $scope = "dsh_config_git_backup($($mode.ToLower())) → 全量"
    foreach ($a in (Get-AllSkillNames $skillsRoot)) { [void]$targetSkills.Add($a) }
}
elseif ($toolName -match '^(pwsh|powershell|bash|sh|cmd)$') {
    # shell 里改了哪个文件无法精确判定：只有命令行同时出现 skills 与写操作迹象时才全量审核
    $cmd = ''
    if ($toolInput) {
        $cp = $toolInput.PSObject.Properties | Where-Object { $_.Name -eq 'command' }
        if ($cp) { $cmd = [string]$cp.Value }
    }
    if (-not $cmd) { exit 0 }
    if ($cmd -notmatch '(?i)skills') { exit 0 }
    if ($cmd -notmatch '(?i)Set-Content|Out-File|Add-Content|Clear-Content|Copy-Item|Move-Item|Remove-Item|New-Item|robocopy|git\s+(checkout|restore|apply)') { exit 0 }
    $scope = "$toolName → 命令行涉及 skills 目录（全量审核）"
    foreach ($a in (Get-AllSkillNames $skillsRoot)) { [void]$targetSkills.Add($a) }
}
else {
    foreach ($p in (Get-CandidatePaths $toolInput)) {
        $full = $p
        if (-not [System.IO.Path]::IsPathRooted($full)) {
            if ($payload.cwd) { $full = Join-Path ([string]$payload.cwd) $p }
        }
        try { $full = [System.IO.Path]::GetFullPath($full) } catch { continue }
        if (-not $full.StartsWith($skillsRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $rel = $full.Substring($skillsRoot.Length).TrimStart('\', '/')
        $seg = ($rel -split '[\\/]')[0]
        if ($seg) { [void]$targetSkills.Add($seg) }
    }
    if ($targetSkills.Count -eq 0) { exit 0 }
    $scope = "$toolName → 技能 " + (($targetSkills | Sort-Object -Unique) -join ', ')
}

$targetSkills = @($targetSkills | Sort-Object -Unique)
# 只审真实存在的技能目录（新建技能时 SKILL.md 可能还没写）
$existing = @($targetSkills | Where-Object { Test-Path -LiteralPath (Join-Path $skillsRoot $_) })
if ($existing.Count -eq 0) { exit 0 }

# —— 3) 跑审核 ——
$auditJson = ''
try { $auditJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $auditScript -Skill $existing -Json 2>$null }
catch { exit 0 }
if (-not $auditJson) { exit 0 }

$report = $null
try { $report = ($auditJson -join "`n") | ConvertFrom-Json } catch { exit 0 }
if (-not $report) { exit 0 }

# —— 4) 有问题才回传上下文（通过时保持安静，只留日志）——
$problem = @($report.results | Where-Object { $_.status -ne 'pass' })
if ($problem.Count -eq 0) { exit 0 }

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("【技能审核 skill-audit】范围：$scope")
foreach ($r in $problem) {
    $mark = if ($r.status -eq 'fail') { '未通过' } else { '有注意项' }
    [void]$lines.Add("· $($r.skill)：$mark（fail $($r.fails) / warn $($r.warns)）")
    $shown = @($r.findings | Where-Object { $_.level -ne 'info' } | Select-Object -First 4)
    foreach ($f in $shown) { [void]$lines.Add("    - [$($f.level)] $($f.message)") }
    $rest = @($r.findings | Where-Object { $_.level -ne 'info' }).Count - $shown.Count
    if ($rest -gt 0) { [void]$lines.Add("    … 另有 $rest 项，见 ~/.dsh/vet/skill-audits/latest.json") }
}
[void]$lines.Add('修复后重跑：powershell -NoProfile -ExecutionPolicy Bypass -File "' + $auditScript + '" -Skill ' + (($problem | Select-Object -ExpandProperty skill) -join ','))
[void]$lines.Add('判据与误报处置见 skill-audit 技能（若某项判断不适用，在技能正文里写明例外与理由，而不是放宽脚本）。')

Write-HookContext ($lines -join "`n")
exit 0
