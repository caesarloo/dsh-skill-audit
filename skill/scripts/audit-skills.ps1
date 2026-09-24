#Requires -Version 5.1
<#
.SYNOPSIS
    DSH 技能静态审核（skill-audit）—— 对技能目录做确定性检查，输出人读报告或 JSON。

.DESCRIPTION
    审核项（代码即判据，避免"看着像没问题"）：
      F1  frontmatter 契约：name / description 必填；name 须 kebab-case 且与目录名一致；
          whenToUse 建议存在；version / last_updated 建议存在        → fail / warn
      S1  脚本可用性：技能内所有 .ps1 必须是 UTF-8 with BOM，且能被
          PowerShell 5.1 解析（errs=0）—— 无 BOM 的中文脚本在 5.1 下按 GBK
          解码会解析失败                                              → fail
      R1  引用完整性：SKILL.md 里 `scripts/xxx.ps1` 这类相对路径引用必须真实存在；
          子目录在而文件缺 = fail（真断裂）；引用落在**别的技能**里 = warn（跨技能引用，
          应改为点名技能名 + related_skills）；都不在 = warn（运行时生成/外部来源）。
          跨技能引用**相对与绝对两种形态都判**：相对形态按引用解析，绝对形态
          （`…\skills\<别的技能>\…`）按路径里的技能名比对（自身路径除外）      → fail / warn
      R2  脚本被引用：技能内脚本未被 SKILL.md 提及                       → info
      F2  依赖声明：related_skills 的自依赖 / 重复项（**存在性不在此判定**：技能名可由
          插件运行时注册、磁盘无 SKILL.md，静态检查必误报 → 归插件侧）        → warn
      E1  审核扩展：audit_extension 声明的扩展缺失 / 无 BOM / 解析失败 / 抛错 → 记在
          声明者身上且只报一次（坏扩展立即停用）                            → warn
      M1  豁免标记契约：audit:ignore 标记缺代码或理由不足 8 字符         → warn
      X1  敏感信息：口令 / token / 私钥特征串                          → fail
      X2  机器专属硬编码路径（C:\Users\<具体用户名>）                   → info
      X3  危险命令（递归强删、注册表删除等）                            → info
      V1  版本号格式：version 必须是三段式 主.次.修（形如 1.2.3）        → fail
      V2  版本号递增：技能位于 git 工作副本、且 SKILL.md 有未提交改动时，与 HEAD
          那一版比较——降级 = 倒退；同级而内容有实质改动 = 忘了 bump（忽略空白的
          纯排版改动不报）；取不到 git 上下文一律静默跳过               → warn

    版本号规则（真源：用户全局指令「技能版本号」）：重构升第一级、新功能升第二级、
    修 bug 升第三级，进位归零。**分级正确性不可静态判定**（要看改动性质，属人判），
    引擎只把守两件可判定的：格式三段式（V1）、相对上一版不倒退且实质改动须 bump（V2）。

    例外豁免（详见 Get-AuditWaivers）：
      SKILL.md 里的 <!-- audit:ignore <代码> <目标> <理由，至少 8 字符> -->
      可跳过 warn / info 级误报（逐条、带理由）；fail 级**不可**豁免，判据本身不放宽。

    退出码：0 = 无 fail；1 = 至少一项 fail（须修复）；2 = 参数/路径错误。
    本脚本自身必须带 UTF-8 BOM，并由 powershell(5.1) 或 pwsh 执行。

.PARAMETER Skill
    技能名（可多个，逗号分隔）；缺省审核 SkillsRoot 下全部技能。

.PARAMETER SkillsRoot
    技能根目录；缺省 $env:DSH_HOME\skills，再回落 ~\.dsh\skills。

.PARAMETER Json
    以 JSON 输出（供钩子/机器消费）。

.PARAMETER NoLog
    不写审核日志（默认写入 <DSH_HOME>\vet\skill-audits\）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File audit-skills.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File audit-skills.ps1 -Skill my-skill-a,my-skill-b -Json
#>
[CmdletBinding()]
param(
    [string[]]$Skill,
    [string]$SkillsRoot,
    [switch]$Json,
    [switch]$NoLog
)

# 审核日志是确定性检查的留痕（本机目录，不进同步面）；只保留最近 40 份避免堆积。
$ErrorActionPreference = 'Continue'

# -Skill 的逗号兼容：`powershell -File script.ps1 -Skill a,b` 在 -File 模式下**不会**把逗号解析成
# 数组（得到单个 "a,b" 字符串），而 dsh-skill-audit 插件正是以子进程 argv 方式传入 skills.join(',')——
# 不兼容会让「多技能定向审核」直接报「技能不存在：a,b」（2026-09-17 实测）。这里统一按逗号拆分，
# 使 CLI（`.\audit-skills.ps1 -Skill a,b`）与插件子进程调用的行为一致。
if ($Skill) {
    $Skill = @($Skill | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# stdout 统一 UTF-8：5.1 默认按控制台代码页(GBK)写输出，消费方（插件用 Node 按 UTF-8 解码、
# 钩子按 UTF-8 读）会拿到乱码。显式设置后，本脚本在任何宿主里的输出编码都一致。
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Get-DshHome {
    if ($env:DSH_HOME) { return $env:DSH_HOME }
    return (Join-Path $env:USERPROFILE '.dsh')
}

if (-not $SkillsRoot) { $SkillsRoot = Join-Path (Get-DshHome) 'skills' }
if (-not (Test-Path -LiteralPath $SkillsRoot)) {
    Write-Error "技能根目录不存在：$SkillsRoot"
    exit 2
}
$SkillsRoot = (Resolve-Path -LiteralPath $SkillsRoot).Path

# —— 审核项实现 ————————————————————————————————————————————————

function Get-FrontmatterText {
    param([string]$Text)
    if (-not $Text.StartsWith('---')) { return $null }
    $end = $Text.IndexOf("`n---", 3)
    if ($end -lt 0) { return $null }
    return $Text.Substring(3, $end - 3)
}

function Get-FrontmatterField {
    param([string]$Frontmatter, [string]$Key)
    if (-not $Frontmatter) { return $null }
    $m = [regex]::Match($Frontmatter, "(?m)^$([regex]::Escape($Key))\s*:\s*(.+?)\s*$")
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value.Trim()
    $v = $v.Trim('"').Trim("'")
    return $v
}

function Test-KebabCase {
    param([string]$Name)
    return ($Name -match '^[a-z0-9]+(-[a-z0-9]+)*$')
}

# —— V1 / V2 版本号判据（2026-09-24 新增）——
# 规则真源是用户全局指令的「技能版本号」一节：重构升第一级、新功能升第二级、修 bug 升第三级，
# 进位归零。**分级正确性引擎判不了**（那要看改动性质），所以引擎只把守两件可判定的：
#   V1 格式：一律三段式 主.次.修（fail，明确契约）。
#   V2 递增：与"上一版"比较。上一版取 git HEAD——**只在技能目录位于 git 工作副本、且 SKILL.md
#      有未提交改动时**才判：那一刻 HEAD 恰好就是上一版。已提交（工作区与 HEAD 一致）说明没有
#      "改动后忘 bump"的问题；非 git 目录（如活跃源技能根）拿不到上下文；新文件 HEAD 里没有。
#      这三种情况一律**静默跳过**——宁可漏报，不可误报（审核一旦有噪音就会被无视）。
function Test-Semver {
    param([string]$Value)
    return [bool]($Value -match '^\d+\.\d+\.\d+$')
}

# git 根探测按技能根缓存：同一根下的多个技能共享一次判定；非 git 根只探一次。
$script:GitTopCache = @{}

function Get-GitTopLevel {
    param([string]$Root)
    if ($script:GitTopCache.ContainsKey($Root)) { return $script:GitTopCache[$Root] }
    $top = $null
    try {
        $out = @(& git -C $Root rev-parse --show-toplevel 2>$null)
        # 两处归一化后再比较：① git 在 Windows 返回正斜杠（C:/x/y）→ 转反斜杠；
        # ② $SkillDir 来自 Resolve-Path，可能是 8.3 短名（C:\Users\<USER>~1\...，用户名超 8 字符时
        #    必然如此）→ GetFullPath 展开成长名。少任何一步，调用方的 StartsWith 都不成立、
        #    V2 静默失效（2026-09-24 实测：两类都踩过）。
        if ($LASTEXITCODE -eq 0 -and $out.Count -gt 0) {
            $top = ([System.IO.Path]::GetFullPath($out[0].Trim()) -replace '/', '\').TrimEnd('\')
        }
    }
    catch { $top = $null }
    $script:GitTopCache[$Root] = $top
    return $top
}

# 返回 @{ version = <HEAD 里的 version 或 $null>; trivial = $true 表示忽略空白后无差异 }；
# 无法取得基线（非 git、无未提交改动、HEAD 无该文件、git 不可用）→ 返回 $null。
function Get-BaselineSkillVersion {
    param([string]$SkillDir, [string]$Root)
    $top = Get-GitTopLevel $Root
    if (-not $top) { return $null }
    # 两侧都归一化成「反斜杠 + 长名」形态再比（$SkillDir 来自 Resolve-Path，可能是 8.3 短名）
    $dirNorm = ([System.IO.Path]::GetFullPath($SkillDir) -replace '/', '\').TrimEnd('\')
    if (-not $dirNorm.StartsWith($top, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    $rel = $dirNorm.Substring($top.Length).TrimStart('\') -replace '\\', '/'
    $relPath = if ($rel) { "$rel/SKILL.md" } else { 'SKILL.md' }
    try {
        $status = @(& git -C $top status --porcelain -- $relPath 2>$null | Where-Object { $_ -match '\S' })
        if ($status.Count -eq 0) { return $null }
        $head = @(& git -C $top show "HEAD:$relPath" 2>$null)
        $ver = $null
        $trivial = $false
        if ($head.Count -gt 0) {
            $headText = $head -join "`n"
            $fm = Get-FrontmatterText $headText
            if ($fm) { $ver = Get-FrontmatterField $fm 'version' }
            # 纯排版判定：忽略**全部空白**（空行、缩进、行尾、文件末尾换行）后内容相同 → 可不 bump。
            # 刻意不用 `git diff -w`：它不忽略 CRLF/LF 与「文件末尾无换行」这两类差异，会把纯排版
            # 判成实质改动而误报（2026-09-24 探针实测：只追加一个空行也报 V2）。
            $workPath = Join-Path $SkillDir 'SKILL.md'
            if (Test-Path -LiteralPath $workPath) {
                $workText = [System.IO.File]::ReadAllText($workPath)
                $trivial = (($workText -replace '\s', '') -eq ($headText -replace '\s', ''))
            }
        }
        return [pscustomobject]@{ version = $ver; trivial = $trivial }
    }
    catch { return $null }
}

function Test-Utf8Bom {
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

function Test-PsParse {
    param([string]$Path)
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    return @($errs).Count
}

# 敏感串：特征明确才报，避免把文档里的占位符（<token>、sk-xxx）当泄漏。
$script:SecretPatterns = @(
    @{ Name = 'OpenAI 风格 key';   Pattern = 'sk-[A-Za-z0-9_\-]{20,}' },
    @{ Name = 'GitHub token';      Pattern = 'gh[pousr]_[A-Za-z0-9]{30,}' },
    @{ Name = 'npm token';         Pattern = 'npm_[A-Za-z0-9]{30,}' },
    @{ Name = 'AWS access key';    Pattern = 'AKIA[0-9A-Z]{16}' },
    @{ Name = '私钥块';            Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = '明文口令赋值';      Pattern = '(?i)(password|passwd|pwd)\s*[:=]\s*[''"][^''"<>\s]{8,}[''"]' },
    @{ Name = '明文 token 赋值';   Pattern = '(?i)(token|secret|apikey|api_key|accesskey)\s*[:=]\s*[''"][A-Za-z0-9_\-]{16,}[''"]' }
)

function Test-Secrets {
    param([string]$Text)
    $hits = @()
    foreach ($p in $script:SecretPatterns) {
        if ([regex]::IsMatch($Text, $p.Pattern)) { $hits += $p.Name }
    }
    return $hits
}

# 机器专属路径：具体用户名写死（通用写法 $env:USERPROFILE / %USERPROFILE% / ~ 不算）
function Get-MachinePaths {
    param([string]$Text)
    $hits = @()
    foreach ($m in [regex]::Matches($Text, '(?i)C:\\+Users\\+([A-Za-z0-9_.\-]+)')) {
        $u = $m.Groups[1].Value
        if ($u -ne 'Public' -and $u -notmatch '^%' -and $u -ne '<user>') { $hits += $m.Value }
    }
    return @($hits | Sort-Object -Unique)
}

$script:DangerPatterns = @(
    @{ Name = '递归强删'; Pattern = '(?i)Remove-Item[^\r\n]*-Recurse[^\r\n]*-Force' },
    @{ Name = 'rm -rf';   Pattern = '(?i)\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r' },
    @{ Name = '注册表删除'; Pattern = '(?i)reg\s+delete' },
    @{ Name = '磁盘格式化'; Pattern = '(?i)Format-Volume|format\s+[A-Z]:' }
)

function Get-DangerHits {
    param([string]$Text)
    $hits = @()
    foreach ($p in $script:DangerPatterns) {
        if ([regex]::IsMatch($Text, $p.Pattern)) { $hits += $p.Name }
    }
    return $hits
}

# SKILL.md 中的相对资源引用（scripts\… / scripts/… / ./scripts/…）
function Get-RelRefs {
    param([string]$Text)
    $refs = @()
    foreach ($m in [regex]::Matches($Text, '(?i)(?<![\w\\/])(?:\.?[\\/])?(scripts|assets|references)[\\/]([A-Za-z0-9_.\-]+)')) {
        $refs += ($m.Groups[1].Value + '\' + $m.Groups[2].Value)
    }
    return @($refs | Sort-Object -Unique)
}

# 跨技能引用识别：某相对引用在本技能里没有、但在**同根下的另一个技能**里存在 —— 这不是
# "引用断裂"，而是"抄了别的技能的内部路径"（耦合）。判据由此从"文件在不在"升级为"该不该由你
# 来指这个路径"，并直接给出确定修法：正文点名技能名 + frontmatter 登记 related_skills。
# （2026-09-17：用户定下"技能间引用一律解耦"后新增，见 skill-audit §5.1。）
function Find-RefOwner {
    param([string]$Ref, [string]$SelfSkill)
    foreach ($d in @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -eq $SelfSkill) { continue }
        if (Test-Path -LiteralPath (Join-Path $d.FullName $Ref)) { return $d.Name }
    }
    return $null
}

# related_skills 声明解析（frontmatter 里 metadata.hermes.related_skills: [a, b]）
function Get-RelatedSkills {
    param([string]$Frontmatter)
    if (-not $Frontmatter) { return @() }
    $m = [regex]::Match($Frontmatter, '(?m)^\s*related_skills\s*:\s*\[(.*?)\]')
    if (-not $m.Success) { return @() }
    return @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })
}

function New-Finding {
    param([string]$Code, [string]$Level, [string]$Message, [string]$File, [string]$Target = '', [string]$Source = '')
    return [pscustomobject]@{ code = $Code; level = $Level; message = $Message; file = $File; target = $Target; source = $Source }
}

# —— 例外豁免（audit:ignore 标记）——
# 这不是"放宽判据"：判据强度一律不变（真断裂依旧 fail），只是让**技能自己就地声明**某条判据不适用。
# 形式（写在 SKILL.md 里）：<!-- audit:ignore <代码> <目标> <理由，至少 8 字符> -->
#   代码：F1 / S1 / R1 / V1 / V2 / X1 / X2 / X3 之一，或 *（全部）
#         （V1 是 fail 级——fail 一律不可豁免，见 Test-Waived；列出只为说明形态）
#   目标：R1 用相对引用（references/core.md，斜杠两种写法等价）；其它代码用文件名（SKILL.md 或脚本名）
# 为什么要它：skill-audit §五 早已要求"误报就在技能正文写明例外与理由"，但此前写了并不生效——
#   规则与实现脱节，结果只剩两条歪路：要么忍受常驻噪音（久了审核被无视），要么改正文措辞回避正则
#   （那是掩盖检测，更糟）。本机制把"写明例外"变成可执行的唯一正解：逐条、带理由、随技能进 git 可审计。
function Get-RefKey {
    param([string]$Ref)
    if (-not $Ref) { return '' }
    return (($Ref -replace '/', '\').TrimStart('.').TrimStart('\').ToLowerInvariant())
}

function Get-AuditWaivers {
    param([string]$Text)
    $waivers = @(); $bad = @()
    if (-not $Text) { return @{ waivers = @(); bad = @() } }
    foreach ($m in [regex]::Matches($Text, '(?s)<!--\s*audit:ignore\s+(?<codes>[A-Za-z0-9_*\s,]+?)\s+(?<target>\S+)\s+(?<reason>.+?)\s*-->')) {
        $codes = @($m.Groups['codes'].Value -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
        $reason = $m.Groups['reason'].Value.Trim()
        if ($codes.Count -eq 0 -or $reason.Length -lt 8) { $bad += $m.Value; continue }
        $waivers += [pscustomobject]@{ codes = $codes; target = (Get-RefKey $m.Groups['target'].Value); reason = $reason }
    }
    return @{ waivers = @($waivers); bad = @($bad) }
}

function Test-Waived {
    param($Finding, $Waivers)
    # fail 级不可豁免：§五「fail 必须修」是硬线，豁免只用来消解 warn/info 的误报，
    # 否则"真断裂仍是 fail"这条保证会被一个标记悄悄绕过。
    if ($Finding.level -eq 'fail') { return $false }
    $t = if ($Finding.target) { Get-RefKey $Finding.target } else { Get-RefKey $Finding.file }
    foreach ($w in $Waivers) {
        if ($w.codes -notcontains '*' -and $w.codes -notcontains $Finding.code) { continue }
        if ($w.target -and $w.target -eq $t) { return $true }
    }
    return $false
}

function Invoke-SkillAudit {
    param([string]$SkillDir, $Extensions = @(), $ExtErrors = @{}, $ExtRuntime = @{})

    $name = Split-Path $SkillDir -Leaf
    $findings = New-Object System.Collections.ArrayList
    $skillMd = Join-Path $SkillDir 'SKILL.md'

    # —— F1 frontmatter 契约 ——
    $text = ''
    if (-not (Test-Path -LiteralPath $skillMd)) {
        [void]$findings.Add((New-Finding 'F1' 'fail' '缺少 SKILL.md（技能目录必须包含 SKILL.md）' $name))
    }
    else {
        $text = [System.IO.File]::ReadAllText($skillMd)
        $fm = Get-FrontmatterText $text
        if (-not $fm) {
            [void]$findings.Add((New-Finding 'F1' 'fail' 'SKILL.md 缺少 YAML frontmatter（--- 块）' 'SKILL.md'))
        }
        else {
            $fname = Get-FrontmatterField $fm 'name'
            $fdesc = Get-FrontmatterField $fm 'description'
            $fwhen = Get-FrontmatterField $fm 'whenToUse'
            $fver  = Get-FrontmatterField $fm 'version'
            $fupd  = Get-FrontmatterField $fm 'last_updated'

            if (-not $fname) {
                [void]$findings.Add((New-Finding 'F1' 'fail' 'frontmatter 缺少必填字段 name' 'SKILL.md'))
            }
            else {
                if (-not (Test-KebabCase $fname)) {
                    [void]$findings.Add((New-Finding 'F1' 'fail' "name 必须是 kebab-case：$fname" 'SKILL.md'))
                }
                if ($fname -ne $name) {
                    [void]$findings.Add((New-Finding 'F1' 'fail' "frontmatter name($fname) 与目录名($name) 不一致" 'SKILL.md'))
                }
            }
            if (-not $fdesc) {
                [void]$findings.Add((New-Finding 'F1' 'fail' 'frontmatter 缺少必填字段 description（模型据此决定是否加载）' 'SKILL.md'))
            }
            elseif ($fdesc.Length -lt 40) {
                [void]$findings.Add((New-Finding 'F1' 'warn' "description 过短（$($fdesc.Length) 字符），建议写清触发场景与触发词" 'SKILL.md'))
            }
            if (-not $fwhen) {
                [void]$findings.Add((New-Finding 'F1' 'warn' '建议补 whenToUse：写清什么情况下该加载本技能' 'SKILL.md'))
            }
            if (-not $fver) {
                [void]$findings.Add((New-Finding 'F1' 'warn' '建议补 version：便于多机同步时判断新旧' 'SKILL.md'))
            }
            if (-not $fupd) {
                [void]$findings.Add((New-Finding 'F1' 'warn' '建议补 last_updated：便于判断内容是否过期' 'SKILL.md'))
            }

            # —— V1 版本号格式：一律三段式 主.次.修（缺 version 仍由上面的 F1 报）——
            if ($fver -and -not (Test-Semver $fver)) {
                [void]$findings.Add((New-Finding 'V1' 'fail' "version 不是三段式 主.次.修：$fver（应形如 1.2.3）" 'SKILL.md'))
            }
            # —— V2 版本号递增：只在 git 里能取到"上一版"时判定（见 Get-BaselineSkillVersion）——
            if ($fver -and (Test-Semver $fver)) {
                $base = Get-BaselineSkillVersion -SkillDir $SkillDir -Root $SkillsRoot
                if ($base -and $base.version -and (Test-Semver $base.version)) {
                    $curVer = [version]$fver
                    $oldVer = [version]$base.version
                    if ($curVer -lt $oldVer) {
                        [void]$findings.Add((New-Finding 'V2' 'warn' "version 从 $($base.version) 降为 $fver：版本号不得倒退" 'SKILL.md'))
                    }
                    elseif ($curVer -eq $oldVer -and -not $base.trivial) {
                        [void]$findings.Add((New-Finding 'V2' 'warn' "SKILL.md 有实质改动但 version 未变（$fver）：按约定重构升第一级、新功能升第二级、修 bug 升第三级（纯排版可不动）" 'SKILL.md'))
                    }
                }
            }

            # —— F2 依赖声明完整性（只做「文件系统可判定」的部分）——
            # 为什么不查"指向的技能是否存在"：DSH 允许**插件在运行时注册技能**——磁盘上没有 SKILL.md，
            # 只在进程内的技能目录里可见。也就是说"技能名"的解析域是**运行时技能目录**，不是文件
            # 系统；静态脚本查不到，查了必然误报（此检查一上线就误报过：某运行时注册的技能被当成
            # 悬空声明）。故这里只报**一定错**的两种：自依赖、重复项。
            # 「悬空声明」检测需要活的技能目录 → 属**插件侧**能力（见 SKILL.md §2.1 的分层表）。
            $rs = @(Get-RelatedSkills $fm)
            if ($rs -contains $name) {
                [void]$findings.Add((New-Finding 'F2' 'warn' "related_skills 含技能自身（$name）——自依赖无意义" 'SKILL.md' $name))
            }
            foreach ($dj in @($rs | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name)) {
                [void]$findings.Add((New-Finding 'F2' 'warn' "related_skills 存在重复项：$dj" 'SKILL.md' $dj))
            }
        }
    }

    # —— S1 脚本可用性（BOM + 5.1 解析）——
    $ps1 = @(Get-ChildItem -LiteralPath $SkillDir -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue)
    foreach ($f in $ps1) {
        if (-not (Test-Utf8Bom $f.FullName)) {
            [void]$findings.Add((New-Finding 'S1' 'fail' "脚本缺少 UTF-8 BOM（5.1 下中文会按 GBK 解码而解析失败）：$($f.Name)" $f.FullName))
        }
        $errCount = Test-PsParse $f.FullName
        if ($errCount -gt 0) {
            [void]$findings.Add((New-Finding 'S1' 'fail' "脚本解析失败（$errCount 个错误）：$($f.Name)" $f.FullName))
        }
    }

    # —— 例外豁免标记（audit:ignore），见文件头 Get-AuditWaivers 的说明 ——
    $waivers = @()
    $wi = Get-AuditWaivers $text
    $waivers = $wi.waivers
    foreach ($b in $wi.bad) {
        $shown = if ($b.Length -gt 70) { $b.Substring(0, 70) + '…' } else { $b }
        [void]$findings.Add((New-Finding 'M1' 'warn' "audit:ignore 标记无效（理由不足 8 字符或缺代码），已忽略：$shown" 'SKILL.md'))
    }

    # —— R1 引用完整性 ——
    if ($text) {
        # 判据收紧（2026-09-17 实测的误报来源）：
        #   ① 正文举例（如 `scripts/xxx.ps1`）不是引用 → 含占位符的 token 跳过；
        #   ② 引用指向别的技能或外部来源（如 Hermes 的 references/…）时，本技能目录下
        #      根本不存在该子目录 → 只记 warn（否则体检被噪音淹没，最后被无视）；
        #   ③ 只有「子目录确实存在、而其中文件缺失」才是真引用断裂 → fail。
        foreach ($ref in (Get-RelRefs $text)) {
            if ($ref -match '(?i)xxx|<[^>]*>|\.\.\.|\*') { continue }
            $target = Join-Path $SkillDir $ref
            if (Test-Path -LiteralPath $target) { continue }
            $subDir = Split-Path $ref -Parent
            if (-not (Test-Path -LiteralPath (Join-Path $SkillDir $subDir))) {
                # 先判是不是"抄了别的技能的路径"——这比"文件不存在"更具体、且有确定修法。
                $owner = Find-RefOwner -Ref $ref -SelfSkill $name
                if ($owner) {
                    [void]$findings.Add((New-Finding 'R1' 'warn' "跨技能引用：$ref 属于技能 $owner —— 正文应只点名技能名，并在 frontmatter 登记 metadata.hermes.related_skills，不要抄对方内部路径（对方改名即失效）" 'SKILL.md' $ref))
                }
                else {
                    [void]$findings.Add((New-Finding 'R1' 'warn' "SKILL.md 提到 $ref，但本技能没有 $subDir 目录（运行时生成或外部来源可忽略）" 'SKILL.md' $ref))
                }
            }
            else {
                [void]$findings.Add((New-Finding 'R1' 'fail' "SKILL.md 引用的资源不存在：$ref" 'SKILL.md' $ref))
            }
        }
        # —— R1 补充：**绝对形态**的跨技能路径引用 ——
        # 上面的 Get-RelRefs 只收相对引用（scripts/x.ps1），于是 `…\skills\<别的技能>\…` 这种绝对
        # 形态从不进入任何判据：2026-09-18 实测，某技能正文引用了**已被整目录移除**的技能路径，
        # 全量审核全绿、一条都没报（它既不是 BOM 问题，也不是"本技能内文件缺失"）。
        # 判据：路径段里的技能名 ≠ 本技能名 → 跨技能引用（与相对形态同码同级别，修法也一样）。
        # 两类排除：① 自身路径；② 示例/占位符行（`<DSH_HOME>/skills/…`、`xxx`）——后者仅在
        # 该技能名**不是**同根下真实存在的技能时才跳过，免得把真死引用当举例放过。
        $seenAbsOwner = @{}
        foreach ($m in [regex]::Matches($text, '(?<![\w.-])skills[\\/]([A-Za-z0-9][A-Za-z0-9._-]*)[\\/]')) {
            $owner = $m.Groups[1].Value
            if ($owner -eq $name) { continue }
            if ($seenAbsOwner.ContainsKey($owner)) { continue }
            $lineStart = $text.LastIndexOf("`n", [Math]::Max(0, $m.Index - 1))
            if ($lineStart -lt 0) { $lineStart = 0 }
            $lineEnd = $text.IndexOf("`n", $m.Index)
            if ($lineEnd -lt 0) { $lineEnd = $text.Length }
            $line = $text.Substring($lineStart, $lineEnd - $lineStart)
            $ownerIsReal = Test-Path -LiteralPath (Join-Path $SkillsRoot $owner)
            if (-not $ownerIsReal -and $line -match '<[^>]*>|(?i)xxx|\*') { continue }
            $seenAbsOwner[$owner] = $true
            [void]$findings.Add((New-Finding 'R1' 'warn' "跨技能路径引用（绝对形态）：$($m.Value) 指向另一个技能 $owner —— 正文应只点名技能名，并在 frontmatter 登记 metadata.hermes.related_skills；对方改名或移除后即成死引用" 'SKILL.md' $m.Value))
        }
        # 反向：脚本资产未被任何地方引用（提示，不算失败）
        foreach ($f in $ps1) {
            $rel = $f.FullName.Substring($SkillDir.Length).TrimStart('\')
            if ($text -notmatch [regex]::Escape($f.Name)) {
                [void]$findings.Add((New-Finding 'R2' 'info' "脚本未被 SKILL.md 引用：$rel" $rel))
            }
        }
    }

    # —— X1 / X2 / X3 内容侧检查（SKILL.md + 全部文本资产）——
    $textFiles = @()
    if ($skillMd -and (Test-Path -LiteralPath $skillMd)) { $textFiles += $skillMd }
    $textFiles += @(Get-ChildItem -LiteralPath $SkillDir -Recurse -File -Include *.ps1, *.md, *.json, *.sh, *.py, *.yml, *.yaml -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $skillMd } | Select-Object -ExpandProperty FullName)

    $secretHits = @(); $machineHits = @(); $dangerHits = @()
    foreach ($tf in $textFiles) {
        $body = [System.IO.File]::ReadAllText($tf)
        foreach ($h in (Test-Secrets $body)) { $secretHits += "$h @ $(Split-Path $tf -Leaf)" }
        foreach ($h in (Get-MachinePaths $body)) { $machineHits += "$h @ $(Split-Path $tf -Leaf)" }
        foreach ($h in (Get-DangerHits $body)) { $dangerHits += "$h @ $(Split-Path $tf -Leaf)" }
    }
    foreach ($h in @($secretHits | Sort-Object -Unique)) {
        [void]$findings.Add((New-Finding 'X1' 'fail' "疑似凭据/密钥特征：$h" 'SKILL.md'))
    }
    foreach ($h in @($machineHits | Sort-Object -Unique)) {
        [void]$findings.Add((New-Finding 'X2' 'info' "硬编码机器专属路径：$h" '' ($h -split ' @ ')[-1]))
    }
    foreach ($h in @($dangerHits | Sort-Object -Unique)) {
        [void]$findings.Add((New-Finding 'X3' 'info' "含危险命令模式（确认用途）：$h" '' ($h -split ' @ ')[-1]))
    }

    # —— 扩展点：由本地其他技能补充审核（只增不减，见文件头 Get-SkillAuditExtensions 的说明）——
    foreach ($msg in @($ExtErrors[$name])) {
        if ($msg) { [void]$findings.Add((New-Finding 'E1' 'warn' "审核扩展不可用：$msg" 'SKILL.md')) }
    }
    foreach ($e in @($Extensions)) {
        # 已经抛过错的扩展直接停用：同一个坏扩展会作用于**每个**被审技能，逐技能报错会瞬间
        # 淹没报告（2026-09-17 探针实测：一个抛错的扩展会让每个被审技能各多出一条 E1）。
        if ($ExtRuntime.ContainsKey($e.owner)) { continue }
        try {
            foreach ($x in @(Invoke-SkillAuditExtension -Ext $e -SkillName $name -SkillDir $SkillDir -Root $SkillsRoot)) {
                if ($null -eq $x -or -not $x.code) { continue }
                # 级别白名单：扩展不能自造级别（未知值降级为 warn），避免绕过 status 的判定。
                $lvl = if (@('fail', 'warn', 'info') -contains $x.level) { $x.level } else { 'warn' }
                [void]$findings.Add((New-Finding $x.code $lvl $x.message `
                    $(if ($x.file) { $x.file } else { 'SKILL.md' }) `
                    $(if ($x.target) { $x.target } else { '' }) `
                    $e.owner))
            }
        }
        catch {
            # 错误归**声明扩展的那个技能**（谁写的扩展谁修），并带上触发时的被审技能名便于定位。
            # 这里只登记，落地成 E1 由主流程在 owner 的结果上补齐——因为按审核顺序 owner 可能**还没轮到**；
            # 顺手也就实现了"只报一次"。
            $ExtRuntime[$e.owner] = "在审核 $name 时抛错：$($_.Exception.Message)"
        }
    }

    # —— 应用 audit:ignore 例外（判据不放宽，只跳过被显式声明为不适用的条目）——
    if (@($waivers).Count -gt 0) {
        $survivors = @($findings | Where-Object { -not (Test-Waived $_ $waivers) })
        $kept = New-Object System.Collections.ArrayList
        foreach ($s in $survivors) { [void]$kept.Add($s) }
        $findings = $kept
    }

    $fails = @($findings | Where-Object { $_.level -eq 'fail' }).Count
    $warns = @($findings | Where-Object { $_.level -eq 'warn' }).Count
    $status = if ($fails -gt 0) { 'fail' } elseif ($warns -gt 0) { 'warn' } else { 'pass' }

    return [pscustomobject]@{
        skill    = $name
        status   = $status
        fails    = $fails
        warns    = $warns
        scripts  = $ps1.Count
        findings = @($findings)
    }
}

# —— 扩展点：由**本地其他技能**补充审核（audit_extension）——
#
# 声明方式（写在**提供扩展的那个技能**的 frontmatter 里）：
#   metadata:
#     hermes:
#       audit_extension: "scripts/audit-checks.ps1"    # 相对该技能目录
# 契约：扩展脚本定义 Get-SkillAuditFindings，返回 finding 对象数组（code/level/message/file/target）。
#
# 三条设计约束：
#   ① **只增不减**：扩展只能追加发现，不能移除或降级核心判据——核心判据的真源始终是本脚本。
#      故扩展点不破坏"判据单一真源"，它只是让**新**判据各有各的家。
#   ② **出错不拖垮审核**：扩展缺失 / 无 BOM / 解析失败 / 执行抛错 → 记一条 E1 warn 到**声明它的
#      技能**上，审核继续跑完。扩展是本地可信代码，但审核本身绝不能因它而失败。
#   ③ **零影响**：没有任何技能声明 audit_extension 时，本机制完全不参与，行为与引入前一致。
function Get-SkillAuditExtensions {
    param([string]$Root)
    $list = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $md = Join-Path $d.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $md)) { continue }
        $fm = Get-FrontmatterText ([System.IO.File]::ReadAllText($md))
        if (-not $fm) { continue }
        $m = [regex]::Match($fm, '(?m)^\s*audit_extension\s*:\s*(.+?)\s*$')
        if (-not $m.Success) { continue }
        $rel = $m.Groups[1].Value.Trim().Trim('"').Trim("'")
        $list += [pscustomobject]@{ owner = $d.Name; path = (Join-Path $d.FullName $rel) }
    }
    return @($list)
}

# dot-source 到**独立函数作用域**再调用：直接 . 进引擎作用域会让扩展脚本覆盖引擎自己的变量
# （$findings / $text / $SkillsRoot …），也会把它的函数定义泄漏到全局。
function Invoke-SkillAuditExtension {
    param($Ext, [string]$SkillName, [string]$SkillDir, [string]$Root)
    . $Ext.path
    if (-not (Get-Command 'Get-SkillAuditFindings' -ErrorAction SilentlyContinue)) {
        throw "扩展脚本未定义 Get-SkillAuditFindings：$($Ext.path)"
    }
    return @(Get-SkillAuditFindings -SkillName $SkillName -SkillDir $SkillDir -SkillsRoot $Root)
}

# —— 主流程 ————————————————————————————————————————————————

$targets = @()
if ($Skill) {
    foreach ($s in $Skill) {
        $d = Join-Path $SkillsRoot $s
        if (Test-Path -LiteralPath $d) { $targets += (Resolve-Path -LiteralPath $d).Path }
        else { Write-Error "技能不存在：$s（根：$SkillsRoot）"; exit 2 }
    }
}
else {
    $targets = @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } |
        Select-Object -ExpandProperty FullName | Sort-Object)
}

# 扩展发现必须在审任何技能**之前**完成：扩展可能声明在本次范围之外的技能上（定向审核时尤其如此）。
$extensions = @()
$extErrors = @{}
foreach ($e in (Get-SkillAuditExtensions $SkillsRoot)) {
    $why = $null
    if (-not (Test-Path -LiteralPath $e.path)) {
        $why = "声明了 audit_extension 但文件不存在：$($e.path)"
    }
    elseif (-not (Test-Utf8Bom $e.path)) {
        $why = "扩展脚本缺少 UTF-8 BOM（5.1 下中文会按 GBK 解码而解析失败）：$($e.path)"
    }
    elseif ((Test-PsParse $e.path) -gt 0) {
        $why = "扩展脚本解析失败（$(Test-PsParse $e.path) 个错误）：$($e.path)"
    }
    if ($why) {
        if (-not $extErrors.ContainsKey($e.owner)) { $extErrors[$e.owner] = @() }
        $extErrors[$e.owner] += $why
    }
    else { $extensions += $e }
}

$ExtRuntime = @{}
$results = @()
foreach ($t in $targets) {
    $results += (Invoke-SkillAudit $t -Extensions $extensions -ExtErrors $extErrors -ExtRuntime $ExtRuntime)
}

# 扩展运行时错误统一补到**声明它的技能**上（原因见 Invoke-SkillAudit 内的说明）：
# 结果对象里的 findings 是定长数组，故这里重建对象并同步重算 status/fails/warns。
if ($ExtRuntime.Count -gt 0) {
    $results = @($results | ForEach-Object {
        $r = $_
        if (-not $ExtRuntime.ContainsKey($r.skill)) { return $r }
        $extra = @([pscustomobject]@{
            code = 'E1'; level = 'warn'; message = "审核扩展执行失败：$($ExtRuntime[$r.skill])"
            file = 'SKILL.md'; target = ''; source = ''
        })
        $all = @($r.findings) + $extra
        $f = @($all | Where-Object { $_.level -eq 'fail' }).Count
        $w = @($all | Where-Object { $_.level -eq 'warn' }).Count
        [pscustomobject]@{
            skill = $r.skill
            status = $(if ($f -gt 0) { 'fail' } elseif ($w -gt 0) { 'warn' } else { 'pass' })
            fails = $f; warns = $w; scripts = $r.scripts; findings = $all
        }
    })
}

$failTotal = @($results | Where-Object { $_.status -eq 'fail' }).Count
$warnTotal = @($results | Where-Object { $_.status -eq 'warn' }).Count

if (-not $NoLog) {
    $logDir = Join-Path (Get-DshHome) 'vet\skill-audits'
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Force -Path $logDir) }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $payload = [pscustomobject]@{
            auditedAt = (Get-Date).ToString('s')
            skillsRoot = $SkillsRoot
            fail = $failTotal
            warn = $warnTotal
            extensions = @($extensions | ForEach-Object { [pscustomobject]@{ owner = $_.owner; path = $_.path } })
            results = $results
        }
        # 局部变量不能叫 $json —— PowerShell 变量名不区分大小写，会撞上本脚本的 [switch]$Json 参数，
        # 赋值字符串时报 "Cannot convert value System.String to type SwitchParameter"（2026-09-17 踩坑）。
        $jsonText = ($payload | ConvertTo-Json -Depth 8)
        [System.IO.File]::WriteAllText((Join-Path $logDir "audit-$stamp.json"), $jsonText, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $logDir 'latest.json'), $jsonText, (New-Object System.Text.UTF8Encoding($false)))
        # 只保留最近 40 份
        $old = @(Get-ChildItem -LiteralPath $logDir -File -Filter 'audit-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 40)
        foreach ($o in $old) { Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue }
    }
    catch { Write-Warning "审核日志写入失败：$($_.Exception.Message)"; Write-Warning $_.InvocationInfo.PositionMessage }
}

if ($Json) {
    $out = [pscustomobject]@{ auditedAt = (Get-Date).ToString('s'); skillsRoot = $SkillsRoot; fail = $failTotal; warn = $warnTotal; extensions = @($extensions | ForEach-Object { $_.owner }); results = $results }
    $out | ConvertTo-Json -Depth 8
}
else {
    Write-Host "==== 技能审核：$SkillsRoot ===="
    Write-Host ("技能数 {0}  |  fail {1}  |  warn {2}{3}" -f $results.Count, $failTotal, $warnTotal,
        $(if ($extensions.Count -gt 0) { "  |  审核扩展 $($extensions.Count) 个：$(($extensions | ForEach-Object { $_.owner }) -join '、')" } else { '' }))
    foreach ($r in $results) {
        $mark = switch ($r.status) { 'pass' { '[通过]' } 'warn' { '[注意]' } default { '[失败]' } }
        Write-Host ("`n$mark {0}  (脚本 {1} 个, fail {2}, warn {3})" -f $r.skill, $r.scripts, $r.fails, $r.warns)
        foreach ($f in $r.findings) {
            if ($f.level -eq 'info') { continue }
            Write-Host ("    - [{0}] {1} ({2}{3})" -f $f.level, $f.message, $f.code, $(if ($f.source) { " @$($f.source)" } else { '' }))
        }
    }
    if ($failTotal -gt 0) { Write-Host "`n存在 fail 项：按上面的 SKILL.md/脚本路径修复后重跑本脚本。" }
}

if ($failTotal -gt 0) { exit 1 }
exit 0
