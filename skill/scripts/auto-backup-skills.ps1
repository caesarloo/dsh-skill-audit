# auto-backup-skills.ps1 — 「改技能 → 自动审核 → 审核通过就自动备份进仓库」通道（宿主: skill-audit-ops）
#
# 为什么需要它：审核插件在被改动的技能上**会自动跑审核**（tools/post-execute），但它的结论只回传给模型、
# 且它**不做任何 git 操作**（2026-11-05 查源码确认）；而 audit_extension 扩展点只能追加判据、不能执行副作用。
# 所以「审核通过后自动入库」这一环由本脚本补：轮询 live 技能根与备份仓 `skills/` 的差异 → 对有差异的技能
# 跑审核引擎 → **fail = 0 才**复制进备份仓并提交（默认连推送）→ 失败只记日志、不动仓库。
#
# 与手工通道的关系：
#   · 手工：改完技能自己调 commit-repo.ps1（闸门 E 要求点名、闸门 F 要求 bump 版本号）；
#   · 本脚本：自动做同样的事，提交信息自动点名、同样受闸门 E / F 约束——**内容改了但没 bump 版本号时，
#     闸门 F 会拦下，本脚本记为 VERSION-NOT-BUMPED 并跳过（不强行 -AllowVersionBypass）**。
#
# 安全边界：
#   · 只把「live 有、仓库缺或内容不同」的文件同步进仓库；**live 删掉的文件不会从仓库删**（只增不删），
#     避免把仓库内容清掉；
#   · **已登记归档的技能一律不写回**（2026-11-05 新增）：读备份仓顶层 `archived-skills.json`，
#     登记过且未恢复（`restoredAt` 为空）的技能跳过、不复制不提交，日志记 `SKIP-ARCHIVED`。
#     为什么：归档要求「从 live 与仓库 skills/ 双双移除」，而本通道只增不删 —— live 侧只要还残留
#     已归档技能，本通道就会把整个目录重新写回仓库，把归档抵消掉（2026-11-05 实测：
#     `company-doc-revision-loop` 的归档提交之后，本通道 18:45 又把它写回仓库，收尾闸门看不见）；
#   · **写回方向护栏（2026-11-13 新增）**：复制前先比 `SKILL.md` 的 `version` —— **仓库版本 ≥ live 版本
#     时一律不写回**（日志 `SKIP-REPO-VERSION`，逐技能标 `SKIP-REPO-NEWER` / `SKIP-REPO-SAME`）。
#     为什么：本机 live 落后远端时，旧实现会把远端新版覆盖成旧 live（2026-11-12 实测 `6052fc3` 把
#     15,621B 的 R8 落地版覆盖成 13,781B），而且事后「bump 再升级」仍从被写回的工作副本取内容、越升越旧；
#   · **合并现场护栏（2026-11-13 新增）**：备份仓存在 `.git\MERGE_HEAD`、或待写回的技能文件里含冲突标记
#     （`<<<<<<<` / `>>>>>>>`）时，本轮整轮跳过（日志 `SKIP-MERGING`）。
#     为什么：自动备份的触发有延迟，人工解冲突期间它不露面，等下一次技能写入才整仓扫描 —— 会把还没解完的
#     合并现场连同错误的版本号一起提交（2026-11-05 实测 `fa2eb63` 把 1.6.1 固化成 1.5.10）；
#   · 审核 fail ≠ 0 → 一个都不提交（整批跳过，日志列出失败条目）；
#   · 暂停开关：暂停文件存在即完全不动作（默认 <DSH_HOME>\vet\skill-auto-backup\PAUSE）；
#   · -DryRun 只报告将做什么，不复制、不提交；
#   · 生成物目录（__pycache__ / node_modules / .git）不参与比对、不复制。
#
# 用法：
#   .\auto-backup-skills.ps1 -Once              # 跑一轮（适合计划任务）
#   .\auto-backup-skills.ps1 -Watch             # 常驻轮询（改完静默 DebounceSeconds 秒后自动入库）
#   .\auto-backup-skills.ps1 -Once -DryRun      # 只看会备份什么
#   .\auto-backup-skills.ps1 -Once -NoPush      # 只本地提交、不推远端
#   .\auto-backup-skills.ps1 -Once -Skills skill-audit-ops,git-workspace-management   # 只处理指定技能
#
# 路径一律现测：live 根取 $env:DSH_HOME\skills；备份仓根取 $env:DSH_CONFIG_GIT_BACKUP_REPO_DIR，
# 否则读活动 profile 的 cordis.patch.yml 里 tool-dsh-config-git-backup 的 config.repoDir；
# 审核引擎取活动 profile 里插件包内的 skill/scripts/audit-skills.ps1（也认 -EnginePath 覆盖）。
# 本脚本必须存为 UTF-8 with BOM（PowerShell 5.1 解析中文必需）。

[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Watch,
    [int]$DebounceSeconds = 10,
    [int]$PollSeconds = 10,
    [switch]$NoPush,
    [switch]$DryRun,
    [string[]]$Skills,
    [string]$LiveRoot,
    [string]$RepoRoot,
    [string]$EnginePath,
    [string]$CommitScript,
    [string]$PauseFile,
    [int]$MaxSkillsPerRun = 10,
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'

# ---------- 路径现测 ----------
# 2026-11-05 补：插件的 ctx.subprocess 起的子进程可能拿不到 DSH_HOME / DSH_PROFILE / USERPROFILE
# （实测干净环境下 DSH_PROFILE 丢失 → 本脚本默认按 web profile 找备份仓配置 → 取不到 repoDir → exit 2）。
# 因此环境变量取不到时，从脚本自身位置反推：包内副本固定落在 <DSH_HOME>\profiles\<profile>\node_modules\...，
# live 副本落在 <DSH_HOME>\skills\<技能名>\scripts\...。
function Resolve-DshHomeFromScriptPath {
    if (-not $PSCommandPath) { return $null }
    $dir = Split-Path -Parent $PSCommandPath
    for ($i = 0; $i -lt 10 -and $dir; $i++) {
        $leaf = Split-Path -Leaf $dir
        if ($leaf -eq 'skills' -or $leaf -eq 'profiles') { return (Split-Path -Parent $dir) }
        $dir = Split-Path -Parent $dir
    }
    return $null
}
function Resolve-ProfileNameFromScriptPath {
    if (-not $PSCommandPath) { return $null }
    $m = [regex]::Match($PSCommandPath, '[\\/]profiles[\\/]([^\\/]+)[\\/]node_modules[\\/]')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.dsh' } else { Resolve-DshHomeFromScriptPath }
$profileName = if ($env:DSH_PROFILE) { $env:DSH_PROFILE } else { $null }
if (-not $profileName) { $profileName = Resolve-ProfileNameFromScriptPath }
if (-not $profileName -and $dshHome) {
    $profilesRoot = Join-Path $dshHome 'profiles'
    if (Test-Path -LiteralPath $profilesRoot) {
        $pdirs = @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'cordis.patch.yml') })
        if ($pdirs.Count -eq 1) { $profileName = $pdirs[0].Name }
    }
}
if (-not $profileName) { $profileName = 'web' }
if (-not $LiveRoot) {
    if (-not $dshHome) { Write-Output '[错误] 取不到 DSH_HOME（也取不到 USERPROFILE）'; exit 2 }
    $LiveRoot = Join-Path $dshHome 'skills'
}
if (-not (Test-Path -LiteralPath $LiveRoot)) { Write-Output ('[错误] live 技能根不存在: ' + $LiveRoot); exit 2 }

function Resolve-BackupRepoRoot {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    $cands = @()
    if ($env:DSH_CONFIG_GIT_BACKUP_REPO_DIR) { $cands += $env:DSH_CONFIG_GIT_BACKUP_REPO_DIR }
    if ($dshHome) {
        $patch = Join-Path (Join-Path (Join-Path $dshHome 'profiles') $profileName) 'cordis.patch.yml'
        if (Test-Path -LiteralPath $patch) {
            try {
                $t = [System.IO.File]::ReadAllText($patch)
                $m = [regex]::Match($t, "config-git-backup[\s\S]{0,600}?repoDir\s*:\s*['`"]?([^'`"\r\n]+)['`"]?")
                if ($m.Success) { $cands += $m.Groups[1].Value.Trim() }
            } catch { }
        }
    }
    foreach ($c in $cands) {
        if (-not $c) { continue }
        $root = $c.Trim().Trim('"').Trim("'")
        if (Test-Path -LiteralPath (Join-Path $root 'skills')) { return $root }
    }
    return $null
}
if (-not $RepoRoot) { $RepoRoot = Resolve-BackupRepoRoot }
if (-not $RepoRoot) { Write-Output '[错误] 取不到备份仓根（环境变量 / profile 配置都没有有效的 skills 目录）'; exit 2 }
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'skills'))) { Write-Output ('[错误] 备份仓里没有 skills 目录: ' + $RepoRoot); exit 2 }

if (-not $EnginePath) {
    $tries = @()
    if ($dshHome) { $tries += (Join-Path $dshHome ('profiles\' + $profileName + '\node_modules\@caesarloo\dsh-skill-audit\skill\scripts\audit-skills.ps1')) }
    if ($dshHome) { $tries += (Join-Path $dshHome 'skills\skill-audit\scripts\audit-skills.ps1') }
    foreach ($t in $tries) { if (Test-Path -LiteralPath $t) { $EnginePath = $t; break } }
}
if (-not $EnginePath -or -not (Test-Path -LiteralPath $EnginePath)) {
    Write-Output '[错误] 找不到审核引擎（可用 -EnginePath 显式指定）'; exit 2
}

if (-not $CommitScript) {
    if ($dshHome) { $CommitScript = Join-Path $dshHome 'skills\git-workspace-management\commit-repo.ps1' }
}
if (-not $CommitScript -or -not (Test-Path -LiteralPath $CommitScript)) {
    Write-Output '[错误] 找不到 commit-repo.ps1（可用 -CommitScript 显式指定）'; exit 2
}

if (-not $PauseFile -and $dshHome) { $PauseFile = Join-Path $dshHome 'vet\skill-auto-backup\PAUSE' }
if (-not $LogPath -and $dshHome) { $LogPath = Join-Path $dshHome ('vet\skill-auto-backup\auto-backup-' + (Get-Date -Format 'yyyyMMdd') + '.log') }
if ($LogPath) {
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
}
$script:LogPath = $LogPath

function Write-Log {
    param([string]$Message)
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message
    Write-Output $line
    if ($script:LogPath) { try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { } }
}

# ---------- 技能文件指纹（排除生成物目录）----------
function Get-SkillFileMap {
    param([string]$Root)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $map }
    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $skill = $dir.Name
        $files = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.FullName -match '\\(__pycache__|node_modules|\.git)\\') { continue }
            $rel = $f.FullName.Substring($dir.FullName.Length).TrimStart('\', '/')
            try { $files[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { }
        }
        if ($files.Count -gt 0 -or (Test-Path -LiteralPath (Join-Path $dir.FullName 'SKILL.md'))) { $map[$skill] = $files }
    }
    return $map
}

# ---------- 已登记归档的技能（2026-11-05 新增护栏，读备份仓 archived-skills.json）----------
function Get-ArchivedSkillNames {
    param([string]$Root)
    $set = @{}
    $p = Join-Path $Root 'archived-skills.json'
    if (-not (Test-Path -LiteralPath $p)) { return $set }
    try { $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { return $set }
    foreach ($a in @($j.archived)) {
        if (-not $a -or -not $a.name) { continue }
        if ($a.restoredAt) { continue }          # 已恢复过的记录不算归档
        $set[[string]$a.name] = $true
    }
    return $set
}

# ---------- 写回方向护栏（2026-11-13，0.3.4）：绝不把仓库改旧 ----------
function Get-SkillVersion {
    param([string]$SkillDir)
    if (-not $SkillDir -or -not (Test-Path -LiteralPath $SkillDir)) { return $null }
    $f = Join-Path $SkillDir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        foreach ($line in (Get-Content -LiteralPath $f -TotalCount 40 -Encoding UTF8)) {
            if ($line -match '^version:\s*(.+?)\s*$') { return $matches[1].Trim().Trim("'").Trim('"') }
        }
    } catch { }
    return $null
}

# 返回 1＝Left 比 Right 新，0＝相同，-1＝Left 比 Right 旧，$null＝无法比较（新建技能/格式不符）
function Compare-SkillVersion {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $null }
    $pl = @($Left.Trim() -split '\.')
    $pr = @($Right.Trim() -split '\.')
    if ($pl.Count -lt 2 -or $pr.Count -lt 2) { return $null }
    $n = [Math]::Max($pl.Count, $pr.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $vl = -1; $vr = -1
        if ($i -lt $pl.Count) { [void][int]::TryParse(($pl[$i] -replace '[^0-9].*$', ''), [ref]$vl) }
        if ($i -lt $pr.Count) { [void][int]::TryParse(($pr[$i] -replace '[^0-9].*$', ''), [ref]$vr) }
        if ($vl -lt 0 -or $vr -lt 0) { return $null }
        if ($vl -gt $vr) { return 1 }
        if ($vl -lt $vr) { return -1 }
    }
    return 0
}

# ---------- 合并现场护栏（2026-11-13，0.3.4）：合并/冲突时本轮跳过 ----------
# 返回命中的原因字符串；$null ＝没有合并现场
function Test-MergeInProgress {
    param([string[]]$SkillNames)
    $gitDir = Join-Path $RepoRoot '.git'
    foreach ($marker in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD')) {
        $p = Join-Path $gitDir $marker
        if (Test-Path -LiteralPath $p) { return ('备份仓存在 .git\' + $marker) }
    }
    if ($SkillNames) {
        foreach ($s in $SkillNames) {
            $dir = Join-Path $LiveRoot $s
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Include *.md,*.ps1,*.json -ErrorAction SilentlyContinue)) {
                try {
                    $head = [System.IO.File]::ReadAllText($f.FullName)
                    if ($head -match '(?m)^<<<<<<< ') { return ('技能文件含冲突标记：' + (Split-Path -Leaf $f.FullName)) }
                } catch { }
            }
        }
    }
    return $null
}

# 只把「live 有、仓库缺或内容不同」算差异；live 删掉的文件不算（只增不删）
# 已登记归档的技能不参与比对（由脚本头部 $script:ArchivedNames 提供，每轮刷新）
function Get-ChangedSkills {
    param([hashtable]$LiveMap, [hashtable]$RepoMap)
    $changed = @()
    foreach ($s in ($LiveMap.Keys | Sort-Object)) {
        if ($Skills -and ($Skills -notcontains $s)) { continue }
        if ($script:ArchivedNames -and $script:ArchivedNames.ContainsKey($s)) { $script:SkippedArchived += $s; continue }
        $lf = $LiveMap[$s]
        if (-not $RepoMap.ContainsKey($s)) { $changed += $s; continue }
        $rf = $RepoMap[$s]
        foreach ($k in $lf.Keys) {
            if (-not $rf.ContainsKey($k) -or $rf[$k] -ne $lf[$k]) { $changed += $s; break }
        }
    }
    return @($changed)
}

# ---------- 解析失败时留原文（只留最近 10 份，写在日志同目录）----------
function Save-AuditRaw {
    param([string]$Stdout, [string]$Stderr, [int]$ExitCode)
    try {
        $dir = $null
        if ($script:LogPath) { $dir = Split-Path -Parent $script:LogPath }
        elseif ($dshHome) { $dir = Join-Path $dshHome 'vet\skill-auto-backup' }
        if (-not $dir) { return $null }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('audit-raw-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
        $body = 'exit=' + $ExitCode + "`n=== stdout ===`n" + $Stdout + "`n=== stderr ===`n" + $Stderr + "`n"
        [System.IO.File]::WriteAllText($f, $body, (New-Object System.Text.UTF8Encoding($false)))
        $old = @(Get-ChildItem -LiteralPath $dir -File -Filter 'audit-raw-*.txt' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10)
        foreach ($o in $old) { Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue }
        return (Split-Path -Leaf $f)
    } catch { return $null }
}

# ---------- 审核（fail = 0 才算通过）----------
# 2026-11-12 改（根因实测）：判据里只要调了外部程序（git / python），那个程序的输出就会混进引擎打到
# stdout 的那份 JSON，ConvertFrom-Json 必失败 → 整轮被记成 AUDIT-ERROR 白白跳过（旧写法还把 stderr 用
# 2>&1 并进 stdout，混得更彻底；2026-11-12 19:25–19:36 连跳 14 轮就是这个）。三层取结果：
#   ① stdout —— stderr 改为单独收（2>$errLines），不再混进 JSON；
#   ② 引擎自己落盘的审核档案 <DSH_HOME>\vet\skill-audits\audit-<时间戳>.json（去掉 -NoLog 它就会写，
#      与 stdout 同一份 payload、UTF-8 无 BOM）——只在①解析不出时回落，且必须核对档案里的技能集合
#      与本轮点名的一致，绝不拿别的轮次的结果放行未审核的内容；
#   ③ 两层都不行 → 原文整份留档成 audit-raw-*.txt，本轮仍按失败跳过（fail-closed 不变）。
function Invoke-SkillAudit {
    param([string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return $null }
    $auditDir = if ($dshHome) { Join-Path $dshHome 'vet\skill-audits' } else { $null }
    # 调用前快照已存在的档案：回落只认「本轮新产生」的那份，否则同一批技能在 2 秒窗口内重跑时会读到
    # 上一轮的结果（2026-11-13 隔离测试 T5 实测命中：上一轮档案被误用，本该 AUDIT-ERROR 反而放行）
    $preAuditFiles = @{}
    if ($auditDir -and (Test-Path -LiteralPath $auditDir)) {
        foreach ($pf in @(Get-ChildItem -LiteralPath $auditDir -File -Filter 'audit-*.json' -ErrorAction SilentlyContinue)) { $preAuditFiles[$pf.Name] = $true }
    }
    $started = Get-Date
    $errLines = @()
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $EnginePath -SkillsRoot $LiveRoot -Skill ($Names -join ',') -Json 2>$errLines
    $code = $LASTEXITCODE
    $text = ($out | Out-String)
    $obj = $null
    try { $obj = $text | ConvertFrom-Json } catch { }
    $via = 'stdout'
    if (-not $obj -and $auditDir -and (Test-Path -LiteralPath $auditDir)) {
        foreach ($cf in @(Get-ChildItem -LiteralPath $auditDir -File -Filter 'audit-*.json' -ErrorAction SilentlyContinue |
                          Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } |
                          Sort-Object LastWriteTime -Descending)) {
            if ($preAuditFiles.ContainsKey($cf.Name)) { continue }
            $o2 = $null
            try { $o2 = ([System.IO.File]::ReadAllText($cf.FullName, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json } catch { continue }
            if (-not $o2 -or -not $o2.results) { continue }
            $got = @($o2.results | ForEach-Object { $_.skill })
            if (@($Names | Where-Object { $got -notcontains $_ }).Count -gt 0) { continue }
            $obj = $o2; $via = 'audit-json'; break
        }
    }
    $fails = @()
    if ($obj) {
        foreach ($r in @($obj.results)) {
            foreach ($f in @($r.findings)) {
                if ($f.level -eq 'fail') { $fails += ('[' + $r.skill + '] ' + $f.code + ' ' + $f.message) }
            }
        }
    }
    $errText = (@($errLines) | ForEach-Object { ("$_").Trim() } | Where-Object { $_ }) -join "`n"
    # fail-closed：三层都拿不到结果（引擎异常 / 技能不存在 / 参数错）一律当失败，绝不默认放行
    if (-not $obj) {
        $dump = Save-AuditRaw -Stdout $text -Stderr $errText -ExitCode $code
        $note = if ($dump) { '原文已留档 ' + $dump } else { '原文留档也失败' }
        return [pscustomobject]@{ ExitCode = $code; FailCount = -1; Fails = @("审核结果无法解析（$note），已按 fail-closed 处理"); Raw = ($text + "`n[stderr] " + $errText) }
    }
    if ($via -ne 'stdout') {
        Write-Log ('AUDIT-FALLBACK stdout 被外部程序输出污染，本轮改用引擎落盘审核档案解析（' + @($obj.results).Count + ' 个技能，已核对技能集合与本轮点名一致）')
    }
    return [pscustomobject]@{ ExitCode = $code; FailCount = @($fails).Count; Fails = $fails; Raw = $text }
}

# ---------- 把 live 技能复制进仓库（只增/覆盖，不删除）----------
function Sync-SkillToRepo {
    param([string]$Name)
    $src = Join-Path $LiveRoot $Name
    $dst = Join-Path (Join-Path $RepoRoot 'skills') $Name
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    & robocopy $src $dst /E /XD __pycache__ node_modules .git /NFL /NDL /NJH /NJS /NP 2>&1 | Out-Null
    return ($LASTEXITCODE -lt 8)
}

# ---------- 处理一轮 ----------
function Invoke-OneRound {
    if ($PauseFile -and (Test-Path -LiteralPath $PauseFile)) { Write-Log 'PAUSED 暂停文件存在，本轮跳过'; $script:RoundResult = 'PAUSED'; return }
    # 合并现场护栏（2026-11-13）：合并/冲突没解完时整轮跳过，不替人把现场提交进仓
    $mergeReason = Test-MergeInProgress -SkillNames @($Skills)
    if ($mergeReason) {
        Write-Log ('SKIP-MERGING ' + $mergeReason + '，本轮跳过：自动备份不替人提交没解完的合并现场')
        $script:RoundResult = 'SKIP-MERGING'; return
    }
    $script:ArchivedNames = Get-ArchivedSkillNames $RepoRoot
    $script:SkippedArchived = @()
    $liveMap = Get-SkillFileMap $LiveRoot
    $repoMap = Get-SkillFileMap (Join-Path $RepoRoot 'skills')
    $changed = Get-ChangedSkills -LiveMap $liveMap -RepoMap $repoMap
    if ($script:SkippedArchived.Count -gt 0) {
        Write-Log ('SKIP-ARCHIVED 以下技能已登记归档（archived-skills.json），不写回仓库：' + ((@($script:SkippedArchived) | Sort-Object -Unique) -join ', '))
    }
    if ($changed.Count -eq 0) { Write-Log 'NO-CHANGE 两侧一致，无需备份'; $script:RoundResult = 'NO-CHANGE'; return }
    # 写回方向护栏（2026-11-13）：仓库版本 ≥ live 版本 → 不写回，绝不把仓库改旧
    $skippedVersion = @()
    $kept = @()
    foreach ($s in $changed) {
        $lv = Get-SkillVersion (Join-Path $LiveRoot $s)
        $rv = Get-SkillVersion (Join-Path (Join-Path $RepoRoot 'skills') $s)
        $cmp = Compare-SkillVersion -Left $rv -Right $lv
        if ($null -ne $cmp -and $cmp -ge 0) { $skippedVersion += [pscustomobject]@{ Skill = $s; Repo = $rv; Live = $lv; Cmp = $cmp }; continue }
        $kept += $s
    }
    if ($skippedVersion.Count -gt 0) {
        foreach ($x in $skippedVersion) {
            if ($x.Cmp -gt 0) { Write-Log ('    SKIP-REPO-NEWER  ' + $x.Skill + '：仓库 ' + $x.Repo + ' 高于 live ' + $x.Live + '（本机 live 落后，先升级再改）') }
            else { Write-Log ('    SKIP-REPO-SAME   ' + $x.Skill + '：仓库与 live 版本同为 ' + $x.Live + ' 但内容不同（若确实改了内容，请 bump 版本号后重试）') }
        }
        Write-Log ('SKIP-REPO-VERSION 以下技能因仓库版本不低于 live 而不写回：' + (($skippedVersion | ForEach-Object { $_.Skill }) -join ', '))
    }
    $changed = @($kept)
    if ($changed.Count -eq 0) { Write-Log 'NO-CHANGE 剩余差异都因仓库版本不低于 live 被护栏跳过，本轮不写回'; $script:RoundResult = 'SKIP-REPO-VERSION'; return }
    if ($changed.Count -gt $MaxSkillsPerRun) {
        Write-Log ('LIMIT 本轮差异技能 ' + $changed.Count + ' 个，超过上限 ' + $MaxSkillsPerRun + '，只处理前 ' + $MaxSkillsPerRun + ' 个')
        $changed = @($changed | Select-Object -First $MaxSkillsPerRun)
    }
    Write-Log ('CHANGED 待审核技能：' + ($changed -join ', '))
    if ($DryRun) {
        Write-Log 'DRYRUN 只报告：将审核并（通过后）复制入库的技能如上；本轮不做任何写入'
        $script:RoundResult = 'DRYRUN'; return
    }
    $audit = Invoke-SkillAudit -Names $changed
    if (-not $audit) { Write-Log 'AUDIT-ERROR 审核没有返回结果，本轮跳过'; $script:RoundResult = 'AUDIT-ERROR'; return }
    if ($audit.FailCount -lt 0) {
        $brief = (($audit.Raw -split "`n") | Select-Object -First 3) -join ' | '
        Write-Log ('AUDIT-ERROR 审核引擎异常（exit ' + $audit.ExitCode + '），本轮跳过：' + $brief)
        $script:RoundResult = 'AUDIT-ERROR'; return
    }
    if ($audit.FailCount -gt 0) {
        Write-Log ('AUDIT-FAIL 审核未通过（fail ' + $audit.FailCount + ' 条），本轮不备份：')
        @($audit.Fails | Select-Object -First 8) | ForEach-Object { Write-Log ('    ' + $_) }
        $script:RoundResult = 'AUDIT-FAIL'; return
    }
    Write-Log 'AUDIT-PASS 审核通过（fail 0），开始复制进备份仓'
    $synced = @()
    foreach ($s in $changed) {
        if (Sync-SkillToRepo -Name $s) { $synced += $s; Write-Log ('    copied  skills/' + $s) }
        else { Write-Log ('    COPY-FAIL  skills/' + $s + '（robocopy 退出码异常，本轮跳过该技能）') }
    }
    if ($synced.Count -eq 0) { Write-Log 'COPY-FAIL 没有任何技能复制成功，本轮不提交'; $script:RoundResult = 'COPY-FAIL'; return }
    $paths = @($synced | ForEach-Object { 'skills/' + $_ })
    $msg = '技能自动备份：' + ($synced -join ', ') + '（本机自动通道：审核 fail 0 后入库）'
    $commitArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CommitScript, '-Repo', $RepoRoot, '-Message', $msg, '-Paths', ($paths -join ','))
    if (-not $NoPush) { $commitArgs += '-Push' }
    $cOut = & powershell @commitArgs 2>&1
    $cCode = $LASTEXITCODE
    $cText = ($cOut | Out-String)
    if ($cCode -eq 0) {
        Write-Log ('BACKUP-OK ' + ($synced -join ', ') + ' 已入库' + $(if ($NoPush) { '（未推送）' } else { '（已提交并推送）' }))
        $script:RoundResult = 'BACKUP-OK'; return
    }
    # 注意：只匹配“拦截”形态。通过时 commit-repo 也会打印“[闸门 F] 通过：…”，
    # 用裸 '闸门 F' 匹配会把“通过但后段提交失败”误判成未 bump（2026-11-05 实测踩到）。
    if ($cText -match '\[拦截\]\s*闸门 F') {
        Write-Log ('VERSION-NOT-BUMPED 闸门 F 拦下（内容改了但版本号没升），本轮候选：' + ($synced -join ', ') + '；下一轮会自动重试')
        @($cText -split "`n" | Where-Object { $_ -match '<- 未 bump' } | Select-Object -First 10) | ForEach-Object { Write-Log ('    ' + $_.Trim()) }
        $script:RoundResult = 'VERSION-NOT-BUMPED'; return
    }
    if ($cText -match '\[拦截\]\s*闸门 E') { Write-Log ('GATE-E 闸门 E 拦下（异常，提交信息应已点名）：' + ($synced -join ',')); $script:RoundResult = 'GATE-E'; return }
    if ($cText -match '敏感') { Write-Log ('SENSITIVE-BLOCKED 命中敏感文件拦截：' + ($synced -join ',')); $script:RoundResult = 'SENSITIVE-BLOCKED'; return }
    Write-Log ('COMMIT-FAIL 提交失败（退出码 ' + $cCode + '）：' + ($synced -join ','))
    @($cText -split "`n" | Select-Object -Last 6) | ForEach-Object { Write-Log ('    ' + $_.Trim()) }
    $script:RoundResult = 'COMMIT-FAIL'; return
}

# ---------- 入口 ----------
Write-Log ('=== auto-backup-skills 启动（live=' + $LiveRoot + ' repo=' + $RepoRoot + ' 引擎=' + (Split-Path $EnginePath -Leaf) + '）===')
if (-not $Watch) { $Once = $true }

if ($Once) {
    Invoke-OneRound; $r = $script:RoundResult
    Write-Log ('=== 本轮结束：' + $r + ' ===')
    if ($r -in @('AUDIT-FAIL', 'COMMIT-FAIL', 'COPY-FAIL', 'AUDIT-ERROR')) { exit 1 }
    exit 0
}

# Watch：轮询 + debounce（改完静默 DebounceSeconds 秒后才处理，避免拷到写了一半的文件）
Write-Log ('WATCH 常驻（轮询 ' + $PollSeconds + 's，静默 ' + $DebounceSeconds + 's）')
$prevSig = ''
$lastChangeAt = Get-Date
while ($true) {
    Start-Sleep -Seconds $PollSeconds
    try {
        $script:ArchivedNames = Get-ArchivedSkillNames $RepoRoot
        $script:SkippedArchived = @()
        $liveMap = Get-SkillFileMap $LiveRoot
        $repoMap = Get-SkillFileMap (Join-Path $RepoRoot 'skills')
        $changed = Get-ChangedSkills -LiveMap $liveMap -RepoMap $repoMap
        if ($script:SkippedArchived.Count -gt 0) {
            Write-Log ('SKIP-ARCHIVED 以下技能已登记归档（archived-skills.json），不写回仓库：' + ((@($script:SkippedArchived) | Sort-Object -Unique) -join ', '))
        }
        $sig = (@($changed | Sort-Object) -join ',')
        if ($sig -ne $prevSig) {
            $prevSig = $sig
            $lastChangeAt = Get-Date
            if ($changed.Count -gt 0) { Write-Log ('WATCH 检测到变化，等待静默：' + $sig) }
            continue
        }
        if (-not $sig) { continue }
        $quiet = ((Get-Date) - $lastChangeAt).TotalSeconds
        if ($quiet -lt $DebounceSeconds) { continue }
        Write-Log ('WATCH 静默 ' + [int]$quiet + 's，开始处理：' + $sig)
        Invoke-OneRound; $r = $script:RoundResult
        Write-Log ('=== 本轮结束：' + $r + ' ===')
        $prevSig = ''
    }
    catch {
        Write-Log ('ERROR ' + $_.Exception.Message)
    }
}
