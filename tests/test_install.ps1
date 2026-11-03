# Offline tests for install.ps1 / uninstall.ps1.
# Every child process gets explicit temporary config directories; the real
# home directory is never modified. This file must stay ASCII-only.

$ErrorActionPreference = 'Continue'

$ScriptDir = [System.IO.Path]::GetFullPath((Split-Path -Parent ([System.IO.Path]::GetFullPath($PSCommandPath))))
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..'))
$InstallScript = Join-Path $RepoRoot 'install.ps1'
$UninstallScript = Join-Path $RepoRoot 'uninstall.ps1'
$TemplatesDir = Join-Path $RepoRoot 'templates'

$PowerShellPath = (Get-Process -Id $PID).Path
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-orchestration-ps-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

$script:Failures = 0
$script:CaseFailed = $false
$script:CaseNumber = 0
$script:CaseBase = ''
$script:CaseLog = ''
$script:ClaudeDir = ''
$script:CodexDir = ''
$script:ConfigDir = ''

function Write-Failure([string]$Message) {
    [Console]::Error.WriteLine("Error: $Message")
}

function Fail([string]$Message) {
    $script:CaseFailed = $true
    Write-Host "  FAIL: $Message"
}

function Test-PathEntry([string]$Path) {
    if ([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)) {
        return $true
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ($null -ne $item)
    } catch {
        return $false
    }
}

function Test-IsReparsePoint([string]$Path) {
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return $false
    }
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-LinkTargetPath([string]$Path) {
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return $null
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        return $null
    }

    $target = $null
    $targetProperty = $item.PSObject.Properties['Target']
    if ($null -ne $targetProperty) {
        $target = $targetProperty.Value
    }
    if ($null -eq $target) {
        $linkProperty = $item.PSObject.Properties['LinkTarget']
        if ($null -ne $linkProperty) {
            $target = $linkProperty.Value
        }
    }
    if ($null -eq $target) {
        return $null
    }
    if ($target -is [System.Array]) {
        $target = $target[0]
    }
    $target = [string]$target
    if ([string]::IsNullOrEmpty($target)) {
        return $null
    }
    if ($target.StartsWith('\\?\')) {
        $target = $target.Substring(4)
    }
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path), $target)
    }
    try {
        return [System.IO.Path]::GetFullPath($target)
    } catch {
        return $null
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        Fail $Message
    }
}

function Assert-FileExists([string]$Path) {
    Assert-True ([System.IO.File]::Exists($Path)) "File does not exist: $Path"
}

function Assert-DirExists([string]$Path) {
    Assert-True ([System.IO.Directory]::Exists($Path)) "Directory does not exist: $Path"
}

function Assert-Missing([string]$Path) {
    Assert-True (-not (Test-PathEntry $Path)) "Path still exists: $Path"
}

function Assert-LinkTo([string]$Path, [string]$Expected) {
    if (-not (Test-IsReparsePoint $Path)) {
        Fail "Not a link: $Path"
        return
    }
    $actual = Get-LinkTargetPath $Path
    if ($null -eq $actual) {
        Fail "Cannot resolve link target: $Path"
        return
    }
    $expectedFull = [System.IO.Path]::GetFullPath($Expected)
    if (-not ($actual -eq $expectedFull)) {
        Fail "Link target mismatch: $Path -> $actual (expected $expectedFull)"
    }
}

function Assert-NotLink([string]$Path) {
    Assert-True (-not (Test-IsReparsePoint $Path)) "Should not be a link: $Path"
}

function Assert-NoBom([string]$Path, [string]$Label) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-True (-not $hasBom) "$Label has a UTF-8 BOM: $Path"
}

function Get-SkillNames {
    return @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'skills') -Directory | Sort-Object Name | ForEach-Object { $_.Name })
}

function Get-SkillSource([string]$Name) {
    return (Join-Path (Join-Path $RepoRoot 'skills') $Name)
}

function Get-BackupCount([string]$Directory) {
    if (-not [System.IO.Directory]::Exists($Directory)) {
        return 0
    }
    $items = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.bak-*' })
    return $items.Count
}

function Test-BytePrefix([byte[]]$Haystack, [byte[]]$Prefix) {
    if ($Prefix.Length -gt $Haystack.Length) {
        return $false
    }
    for ($i = 0; $i -lt $Prefix.Length; $i++) {
        if ($Haystack[$i] -ne $Prefix[$i]) {
            return $false
        }
    }
    return $true
}

function Test-ByteSequence([byte[]]$Haystack, [byte[]]$Needle) {
    if ($Needle.Length -eq 0) {
        return $true
    }
    if ($Needle.Length -gt $Haystack.Length) {
        return $false
    }
    $limit = $Haystack.Length - $Needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        $matched = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Remove-LinkEntry([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw "Refusing to remove a non-link path: $Path"
    }
    if ($item -is [System.IO.DirectoryInfo]) {
        [System.IO.Directory]::Delete($Path, $false)
    } else {
        [System.IO.File]::Delete($Path)
    }
}

function Remove-TreeSafe([string]$Path) {
    if (-not (Test-PathEntry $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-LinkEntry $Path
        return
    }
    if ($item -is [System.IO.DirectoryInfo]) {
        $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            Remove-TreeSafe $child.FullName
        }
        try {
            [System.IO.Directory]::Delete($Path, $false)
        } catch {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        [System.IO.File]::Delete($Path)
    }
}

function Start-Case {
    $script:CaseNumber = $script:CaseNumber + 1
    $script:CaseBase = Join-Path $TestRoot ("case-" + $script:CaseNumber)
    $script:ClaudeDir = Join-Path $script:CaseBase 'claude'
    $script:CodexDir = Join-Path $script:CaseBase 'codex'
    $script:ConfigDir = Join-Path $script:CaseBase 'config'
    $script:CaseLog = Join-Path $script:CaseBase 'command.log'
    New-Item -ItemType Directory -Path $script:CaseBase -Force | Out-Null
    $env:CLAUDE_CONFIG_DIR = $script:ClaudeDir
    $env:CODEX_HOME = $script:CodexDir
    $env:AGENT_ORCH_HOME = $script:ConfigDir
}

function Show-CaseLog {
    if (-not [System.IO.File]::Exists($script:CaseLog)) {
        return
    }
    $lines = @(Get-Content -LiteralPath $script:CaseLog -ErrorAction SilentlyContinue)
    foreach ($line in $lines) {
        Write-Host "    $line"
    }
}

function Invoke-Script([string]$ScriptPath, [string[]]$Arguments, [string]$LogPath) {
    & $PowerShellPath -NoProfile -File $ScriptPath @Arguments *> $LogPath
    return $LASTEXITCODE
}

function Invoke-Install {
    param([string[]]$Arguments = @())
    $code = Invoke-Script $InstallScript $Arguments $script:CaseLog
    if ($code -ne 0) {
        Fail "install.ps1 failed: $($Arguments -join ' ')"
        Show-CaseLog
    }
    return $code
}

function Invoke-Uninstall {
    param([string[]]$Arguments = @())
    $code = Invoke-Script $UninstallScript $Arguments $script:CaseLog
    if ($code -ne 0) {
        Fail "uninstall.ps1 failed: $($Arguments -join ' ')"
        Show-CaseLog
    }
    return $code
}

function Test-DefaultInstall {
    Start-Case
    if ((Invoke-Install) -ne 0) { return }

    $skills = @(Get-SkillNames)
    Assert-True ($skills.Count -gt 0) 'No skills found in the repository'
    if ($script:CaseFailed) { return }
    foreach ($name in $skills) {
        Assert-LinkTo (Join-Path $script:ClaudeDir "skills/$name") (Get-SkillSource $name)
    }

    $configFile = Join-Path $script:ConfigDir 'config.json'
    Assert-FileExists $configFile
    if ([System.IO.File]::Exists($configFile)) {
        Assert-NoBom $configFile 'config.json'
        try {
            $data = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        } catch {
            Fail "config.json is not valid JSON: $configFile"
            $data = $null
        }
        if ($null -ne $data) {
            Assert-True ($null -ne $data.cli) 'config.json has no cli section'
            if ($script:CaseFailed) {
                return
            }
            $cliKeys = @($data.cli.PSObject.Properties.Name)
            foreach ($key in @('deepseek', 'codex', 'claude')) {
                Assert-True ($cliKeys -contains $key) "config.json is missing cli.$key"
            }
            $topKeys = @($data.PSObject.Properties.Name)
            Assert-True ($topKeys -contains 'protected_paths') 'config.json is missing protected_paths'
        }
    }

    Assert-FileExists (Join-Path $script:ConfigDir 'authorizations.md')
    Assert-DirExists $script:ConfigDir
}

function Test-Idempotent {
    Start-Case
    if ((Invoke-Install) -ne 0) { return }

    $skills = @(Get-SkillNames)
    $linksBefore = @{}
    foreach ($name in $skills) {
        $linksBefore[$name] = Get-LinkTargetPath (Join-Path $script:ClaudeDir "skills/$name")
    }
    $configFile = Join-Path $script:ConfigDir 'config.json'
    $authFile = Join-Path $script:ConfigDir 'authorizations.md'
    $configBefore = (Get-FileHash -LiteralPath $configFile -Algorithm SHA256).Hash
    $authBefore = (Get-FileHash -LiteralPath $authFile -Algorithm SHA256).Hash

    if ((Invoke-Install) -ne 0) { return }

    foreach ($name in $skills) {
        $after = Get-LinkTargetPath (Join-Path $script:ClaudeDir "skills/$name")
        Assert-True ($after -eq $linksBefore[$name]) "Reinstall changed the $name link"
    }
    Assert-True ((Get-FileHash -LiteralPath $configFile -Algorithm SHA256).Hash -eq $configBefore) 'Reinstall rewrote config.json'
    Assert-True ((Get-FileHash -LiteralPath $authFile -Algorithm SHA256).Hash -eq $authBefore) 'Reinstall rewrote authorizations.md'

    $count = Get-BackupCount (Join-Path $script:ClaudeDir 'skills')
    Assert-True ($count -eq 0) "Reinstall produced $count backup(s)"
}

function Test-ExistingDirectoryIsBackedUp {
    Start-Case
    $skillsDir = Join-Path $script:ClaudeDir 'skills'
    $existing = Join-Path $skillsDir 'session-orchestration'
    New-Item -ItemType Directory -Path $existing -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $existing 'sentinel.txt'), "sentinel`n")

    if ((Invoke-Install) -ne 0) { return }

    Assert-LinkTo $existing (Get-SkillSource 'session-orchestration')
    $backups = @(Get-ChildItem -LiteralPath $skillsDir -Force | Where-Object { $_.Name -like 'session-orchestration.bak-*' })
    Assert-True ($backups.Count -gt 0) "No session-orchestration.bak-* backup found"
    if ($script:CaseFailed) { return }
    $foundSentinel = $false
    foreach ($backup in $backups) {
        if ([System.IO.File]::Exists((Join-Path $backup.FullName 'sentinel.txt'))) {
            $foundSentinel = $true
        }
    }
    Assert-True $foundSentinel 'The backup does not contain the original sentinel.txt'
}

function Test-CodexInstall {
    Start-Case
    if ((Invoke-Install @('-Codex')) -ne 0) { return }

    foreach ($name in @(Get-SkillNames)) {
        Assert-LinkTo (Join-Path $script:ClaudeDir "skills/$name") (Get-SkillSource $name)
        Assert-LinkTo (Join-Path $script:CodexDir "skills/$name") (Get-SkillSource $name)
    }
}

function Test-CopyMode {
    Start-Case
    if ((Invoke-Install @('-Copy')) -ne 0) { return }

    $skillsDir = Join-Path $script:ClaudeDir 'skills'
    $skills = @(Get-SkillNames)
    foreach ($name in $skills) {
        $target = Join-Path $skillsDir $name
        Assert-NotLink $target
        Assert-DirExists $target
        Assert-FileExists (Join-Path $target '.agent-orchestration-copy')
    }
    Assert-True ((Get-BackupCount $skillsDir) -eq 0) 'First -Copy run should not produce backups'

    if ((Invoke-Install @('-Copy')) -ne 0) { return }

    foreach ($name in $skills) {
        $target = Join-Path $skillsDir $name
        Assert-NotLink $target
        Assert-DirExists $target
        Assert-FileExists (Join-Path $target '.agent-orchestration-copy')
        Assert-FileExists (Join-Path $target 'SKILL.md')
    }
    Assert-True ((Get-BackupCount $skillsDir) -eq 0) 'Second -Copy run should not produce backups'
}

function Test-ProjectOnly {
    Start-Case
    $project = Join-Path $script:CaseBase 'project'
    New-Item -ItemType Directory -Path $project -Force | Out-Null

    $originalText = "Existing project content, keep me`nSecond line without trailing newline"
    $originalBytes = [System.Text.Encoding]::UTF8.GetBytes($originalText)
    $claudeFile = Join-Path $project 'CLAUDE.md'
    [System.IO.File]::WriteAllBytes($claudeFile, $originalBytes)

    if ((Invoke-Install @('-ProjectOnly', $project)) -ne 0) { return }

    Assert-DirExists (Join-Path $project 'work')
    Assert-DirExists (Join-Path $project 'outputs')

    $templateProject = Join-Path $TemplatesDir 'project'
    if ([System.IO.Directory]::Exists($templateProject)) {
        $templateRoot = (Get-Item -LiteralPath $templateProject -Force).FullName
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $templateProject -Recurse -File -Force)) {
            $relative = $sourceFile.FullName.Substring($templateRoot.Length).TrimStart([char[]]@('\', '/'))
            Assert-FileExists (Join-Path $project $relative)
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($claudeFile)
    Assert-NoBom $claudeFile 'CLAUDE.md'
    Assert-True (Test-BytePrefix $bytes $originalBytes) 'Existing CLAUDE.md content was not preserved byte-for-byte'

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $count = ([regex]::Matches($text, 'agent-orchestration:begin')).Count
    Assert-True ($count -eq 1) "CLAUDE.md snippet appears $count time(s), expected 1"
    Assert-True ($text.Contains('Existing project content, keep me')) 'Existing CLAUDE.md text was lost'

    $snippetFile = Join-Path $TemplatesDir 'CLAUDE.md.snippet'
    $snippetBytes = [System.IO.File]::ReadAllBytes($snippetFile)
    Assert-True (Test-ByteSequence $bytes $snippetBytes) 'CLAUDE.md does not contain the snippet bytes from the template'

    Assert-True (-not (Test-PathEntry $script:ConfigDir)) '-ProjectOnly created the config directory'

    if ((Invoke-Install @('-ProjectOnly', $project)) -ne 0) { return }

    $bytesAfter = [System.IO.File]::ReadAllBytes($claudeFile)
    $textAfter = [System.Text.Encoding]::UTF8.GetString($bytesAfter)
    $countAfter = ([regex]::Matches($textAfter, 'agent-orchestration:begin')).Count
    Assert-True ($countAfter -eq 1) "CLAUDE.md snippet appears $countAfter time(s) after a second run, expected 1"
    Assert-NoBom $claudeFile 'CLAUDE.md after second run'
    Assert-True (Test-BytePrefix $bytesAfter $originalBytes) 'Second run changed the existing CLAUDE.md content'
    Assert-True (Test-ByteSequence $bytesAfter $snippetBytes) 'Second run lost the snippet bytes'
}

function Test-UninstallAndPurge {
    Start-Case

    if ((Invoke-Install @('-Codex')) -ne 0) { return }
    if ((Invoke-Uninstall) -ne 0) { return }
    foreach ($name in @(Get-SkillNames)) {
        Assert-Missing (Join-Path $script:ClaudeDir "skills/$name")
        Assert-Missing (Join-Path $script:CodexDir "skills/$name")
    }
    Assert-DirExists $script:ConfigDir

    if ((Invoke-Install @('-Copy', '-Codex')) -ne 0) { return }
    $skillsDir = Join-Path $script:ClaudeDir 'skills'
    $codexSkillsDir = Join-Path $script:CodexDir 'skills'
    foreach ($name in @(Get-SkillNames)) {
        Assert-FileExists (Join-Path $skillsDir "$name/.agent-orchestration-copy")
        Assert-FileExists (Join-Path $codexSkillsDir "$name/.agent-orchestration-copy")
    }
    $unrelated = Join-Path $skillsDir 'unrelated-dir'
    New-Item -ItemType Directory -Path $unrelated -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $unrelated 'keep.txt'), "keep`n")

    if ((Invoke-Uninstall) -ne 0) { return }
    foreach ($name in @(Get-SkillNames)) {
        Assert-Missing (Join-Path $skillsDir $name)
        Assert-Missing (Join-Path $codexSkillsDir $name)
    }
    Assert-DirExists $unrelated
    Assert-FileExists (Join-Path $unrelated 'keep.txt')
    Assert-DirExists $script:ConfigDir

    if ((Invoke-Uninstall @('-Purge')) -ne 0) { return }
    Assert-Missing $script:ConfigDir
}

function Test-UnknownArgument {
    Start-Case
    $code = Invoke-Script $InstallScript @('-NotARealOption') $script:CaseLog
    Assert-True ($code -ne 0) "install.ps1 returned 0 for an unknown argument (expected non-zero)"
    Assert-True (-not (Test-PathEntry $script:ConfigDir)) 'Unknown argument created the config directory'

    $uninstallCode = Invoke-Script $UninstallScript @('-NotARealOption') $script:CaseLog
    Assert-True ($uninstallCode -ne 0) "uninstall.ps1 returned 0 for an unknown argument (expected non-zero)"
}

function Test-Help {
    Start-Case
    $code = Invoke-Script $InstallScript @('-Help') $script:CaseLog
    Assert-True ($code -eq 0) "install.ps1 -Help returned $code (expected 0)"
    $text = ''
    if ([System.IO.File]::Exists($script:CaseLog)) {
        $text = [System.IO.File]::ReadAllText($script:CaseLog, [System.Text.Encoding]::UTF8)
    }
    Assert-True ($text.Contains('Usage:')) 'install.ps1 -Help did not print usage'
    Assert-True (-not (Test-PathEntry $script:ConfigDir)) 'install.ps1 -Help created the config directory'

    $uninstallCode = Invoke-Script $UninstallScript @('-Help') $script:CaseLog
    Assert-True ($uninstallCode -eq 0) "uninstall.ps1 -Help returned $uninstallCode (expected 0)"
}

function Run-Case([string]$Name, [scriptblock]$Body) {
    $script:CaseFailed = $false
    try {
        & $Body
    } catch {
        Fail "Unexpected exception: $_"
    }
    if ($script:CaseFailed) {
        Write-Host "FAIL $Name"
        $script:Failures = $script:Failures + 1
    } else {
        Write-Host "PASS $Name"
    }
}

Write-Host "Temporary test directory: $TestRoot"

try {
    Run-Case 'default install' { Test-DefaultInstall }
    Run-Case 'idempotent reinstall' { Test-Idempotent }
    Run-Case 'existing directory backup' { Test-ExistingDirectoryIsBackedUp }
    Run-Case 'codex install' { Test-CodexInstall }
    Run-Case 'copy mode' { Test-CopyMode }
    Run-Case 'project-only initialization' { Test-ProjectOnly }
    Run-Case 'uninstall and purge' { Test-UninstallAndPurge }
    Run-Case 'unknown argument exit code' { Test-UnknownArgument }
    Run-Case 'help exit code' { Test-Help }

    if ($script:Failures -ne 0) {
        Write-Host "TESTS FAILED ($($script:Failures) case(s))"
        exit 1
    }
    Write-Host 'ALL TESTS PASSED'
    exit 0
} finally {
    try {
        Remove-TreeSafe $TestRoot
    } catch {
    }
}
