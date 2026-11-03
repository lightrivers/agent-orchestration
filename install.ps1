# Install agent-orchestration skills and local configuration on Windows.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.
# This file must stay ASCII-only: Windows PowerShell 5.1 reads BOM-less
# scripts using the local code page.

[CmdletBinding()]
param(
    [switch]$Copy,
    [switch]$Codex,
    [string]$Project,
    [string]$ProjectOnly,
    [switch]$Check,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$ScriptPath = $PSCommandPath
if ([string]::IsNullOrEmpty($ScriptPath)) {
    $ScriptPath = $MyInvocation.MyCommand.Path
}
$ScriptFull = [System.IO.Path]::GetFullPath($ScriptPath)
$RepoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $ScriptFull))
$TemplatesDir = Join-Path $RepoRoot 'templates'

if ($null -ne $HOME -and -not [string]::IsNullOrEmpty([string]$HOME)) {
    $HomeDir = [string]$HOME
} elseif (-not [string]::IsNullOrEmpty($env:USERPROFILE)) {
    $HomeDir = $env:USERPROFILE
} else {
    $HomeDir = [System.Environment]::GetFolderPath('UserProfile')
}

if ($env:CLAUDE_CONFIG_DIR) {
    $ClaudeRoot = $env:CLAUDE_CONFIG_DIR
} else {
    $ClaudeRoot = Join-Path $HomeDir '.claude'
}
$ClaudeSkillsDir = Join-Path $ClaudeRoot 'skills'

if ($env:CODEX_HOME) {
    $CodexRoot = $env:CODEX_HOME
} else {
    $CodexRoot = Join-Path $HomeDir '.codex'
}
$CodexSkillsDir = Join-Path $CodexRoot 'skills'

if ($env:AGENT_ORCH_HOME) {
    $ConfigDir = $env:AGENT_ORCH_HOME
} else {
    $ConfigDir = Join-Path (Join-Path $HomeDir '.config') 'agent-orchestration'
}

# Windows PowerShell 5.1 has no $IsWindows variable and only runs on Windows.
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $OnWindows = [bool]$IsWindows
} else {
    $OnWindows = $true
}

$InstalledNotes = New-Object System.Collections.Generic.List[string]
$SkippedNotes = New-Object System.Collections.Generic.List[string]
$BackupNotes = New-Object System.Collections.Generic.List[string]

function Show-Usage {
    Write-Host 'Usage: .\install.ps1 [options]'
    Write-Host ''
    Write-Host 'Installs every skill under skills/ into the Claude configuration'
    Write-Host 'directory. All install actions are idempotent.'
    Write-Host ''
    Write-Host 'Options:'
    Write-Host '  -Copy               Copy skills instead of creating links'
    Write-Host '  -Codex              Also install into the Codex skills directory'
    Write-Host '  -Project DIR        Initialize a project directory as well'
    Write-Host '  -ProjectOnly DIR    Initialize only the project directory'
    Write-Host '  -Check              Check status and run offline tests; change nothing'
    Write-Host '  -Help               Show this help'
    Write-Host ''
    Write-Host 'Environment variables:'
    Write-Host '  CLAUDE_CONFIG_DIR   Claude configuration directory (default: ~\.claude)'
    Write-Host '  CODEX_HOME          Codex configuration directory (default: ~\.codex)'
    Write-Host '  AGENT_ORCH_HOME     Tool configuration directory'
    Write-Host '                      (default: ~\.config\agent-orchestration)'
}

function Write-Failure([string]$Message) {
    [Console]::Error.WriteLine("Error: $Message")
}

function Stop-WithError([string]$Message) {
    Write-Failure $Message
    exit 1
}

function Record-Installed([string]$Note) {
    $InstalledNotes.Add($Note) | Out-Null
}

function Record-Skipped([string]$Note) {
    $SkippedNotes.Add($Note) | Out-Null
}

function Record-Backup([string]$Note) {
    $BackupNotes.Add($Note) | Out-Null
}

function Get-NormalizedFullPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $full.TrimEnd($trimChars)
}

function Test-PathEquals([string]$Left, [string]$Right) {
    if ($OnWindows) {
        return ($Left -eq $Right)
    }
    return ($Left -ceq $Right)
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
        return (Get-NormalizedFullPath $target)
    } catch {
        return $null
    }
}

function Test-LinkMatches([string]$Path, [string]$SourceDir) {
    $target = Get-LinkTargetPath $Path
    if ($null -eq $target) {
        return $false
    }
    $source = Get-NormalizedFullPath $SourceDir
    return (Test-PathEquals $target $source)
}

function Resolve-DirectoryPhysical([string]$Path) {
    if (Test-IsReparsePoint $Path) {
        $target = Get-LinkTargetPath $Path
        if ($null -ne $target) {
            return $target
        }
    }
    return (Get-NormalizedFullPath $Path)
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

function Backup-Target([string]$Target) {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backup = "$Target.bak-$stamp"
    $suffix = 1
    while (Test-PathEntry $backup) {
        $backup = "$Target.bak-$stamp-$suffix"
        $suffix = $suffix + 1
    }

    $item = Get-Item -LiteralPath $Target -Force -ErrorAction Stop
    if ($item -is [System.IO.DirectoryInfo]) {
        [System.IO.Directory]::Move($Target, $backup)
    } else {
        [System.IO.File]::Move($Target, $backup)
    }
    Write-Host "Backup: $Target -> $backup"
    Record-Backup "$Target -> $backup"
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Install-Skill([string]$Label, [string]$DestRoot, [string]$Name, [string]$SourceDir, [string]$Mode) {
    if (-not [System.IO.Directory]::Exists($DestRoot)) {
        New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    }

    $target = Join-Path $DestRoot $Name
    $sourceFull = Get-NormalizedFullPath $SourceDir
    $targetFull = Get-NormalizedFullPath $target
    $destRootPhysical = Resolve-DirectoryPhysical $DestRoot
    $targetPhysical = Get-NormalizedFullPath (Join-Path $destRootPhysical $Name)
    if ((Test-PathEquals $targetFull $sourceFull) -or (Test-PathEquals $targetPhysical $sourceFull)) {
        Write-Host "Skip: target is the source directory, not installing into the repository: $target"
        Record-Skipped "${Label}: $Name (target is the source directory)"
        return
    }

    if ($Mode -eq 'link') {
        if (Test-LinkMatches $target $sourceFull) {
            Write-Host "Skip: $target is already linked to $sourceFull"
            Record-Skipped "${Label}: $Name (already linked)"
            return
        }

        if (Test-PathEntry $target) {
            Backup-Target $target
        }

        if ($OnWindows) {
            New-Item -ItemType Junction -Path $target -Target $sourceFull | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $target -Target $sourceFull | Out-Null
        }
        Write-Host "Link: $target -> $sourceFull"
        Record-Installed "${Label}: $Name (link)"
        return
    }

    $isReparse = Test-IsReparsePoint $target
    $marker = Join-Path $target '.agent-orchestration-copy'
    if ((-not $isReparse) -and [System.IO.Directory]::Exists($target) -and [System.IO.File]::Exists($marker)) {
        Remove-Item -LiteralPath $target -Recurse -Force
        Write-Host "Replace: $target (previously copied by this script)"
    } elseif (Test-PathEntry $target) {
        Backup-Target $target
    }

    Copy-Item -LiteralPath $sourceFull -Destination $target -Recurse -Force
    $markerText = "source=$sourceFull`ninstalled_at=$(Get-Date -Format 'yyyyMMddHHmmss')`n"
    Write-Utf8NoBom $marker $markerText
    Write-Host "Copy: $target <- $sourceFull"
    Record-Installed "${Label}: $Name (copy)"
}

function Install-Skills {
    $skillsRoot = Join-Path $RepoRoot 'skills'
    if (-not [System.IO.Directory]::Exists($skillsRoot)) {
        Stop-WithError "Skills directory not found: $skillsRoot"
    }

    $sources = @(Get-ChildItem -LiteralPath $skillsRoot -Directory | Sort-Object Name)
    foreach ($source in $sources) {
        $name = $source.Name
        $sourceDir = $source.FullName
        Install-Skill 'Claude' $ClaudeSkillsDir $name $sourceDir $Mode
        if ($Codex) {
            Install-Skill 'Codex' $CodexSkillsDir $name $sourceDir $Mode
        }
    }

    if ($sources.Count -eq 0) {
        Write-Host 'Note: no skill directories found under skills/.'
    }
}

function Expand-UserPath([string]$Path) {
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq '~') {
        return $HomeDir
    }
    if ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        return (Join-Path $HomeDir $expanded.Substring(2))
    }
    return $expanded
}

function Find-CliPath([string]$Key, [string]$CommandName, [string]$CurrentValue) {
    $candidate = ''
    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        $candidate = Expand-UserPath $CurrentValue
        if ([System.IO.File]::Exists($candidate)) {
            return $candidate
        }
    }

    $found = Get-Command -Name $CommandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $found) {
        $found = Get-Command -Name $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $found) {
        return ''
    }

    $source = [string]$found.Source
    if ([string]::IsNullOrEmpty($source)) {
        $pathProperty = $found.PSObject.Properties['Path']
        if ($null -ne $pathProperty -and $null -ne $pathProperty.Value) {
            $source = [string]$pathProperty.Value
        }
    }
    if ([string]::IsNullOrEmpty($source)) {
        return ''
    }
    if ($source -match '(?i)\.(cmd|bat)$') {
        Write-Host "$CommandName resolves to a .cmd shim; set the real .exe path in config.json"
        return ''
    }
    return $source
}

function Configure-AgentOrchestration {
    if ([System.IO.Directory]::Exists($ConfigDir)) {
        Write-Host "Config directory already exists: $ConfigDir"
    } elseif (Test-PathEntry $ConfigDir) {
        Stop-WithError "Config path exists but is not a directory: $ConfigDir"
    } else {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
        Write-Host "Created config directory: $ConfigDir"
    }

    $configFile = Join-Path $ConfigDir 'config.json'
    $configTemplate = Join-Path $TemplatesDir 'config.example.json'
    if (Test-PathEntry $configFile) {
        Write-Host "Preserved existing: $configFile"
    } else {
        if (-not [System.IO.File]::Exists($configTemplate)) {
            Stop-WithError "Config template not found: $configTemplate"
        }
        $templateText = [System.IO.File]::ReadAllText($configTemplate, [System.Text.Encoding]::UTF8)
        $data = $templateText | ConvertFrom-Json
        if ($null -eq $data.PSObject.Properties['cli']) {
            $data | Add-Member -NotePropertyName 'cli' -NotePropertyValue (New-Object PSObject) -Force
        }
        $cli = $data.cli
        if ($null -eq $cli) {
            $cli = New-Object PSObject
            $data | Add-Member -NotePropertyName 'cli' -NotePropertyValue $cli -Force
        }
        $commands = [ordered]@{
            deepseek = 'dsh'
            codex = 'codex'
            claude = 'claude'
        }
        foreach ($key in $commands.Keys) {
            $current = ''
            $property = $cli.PSObject.Properties[$key]
            if ($null -ne $property -and $null -ne $property.Value) {
                $current = [string]$property.Value
            }
            $chosen = Find-CliPath $key $commands[$key] $current
            $cli | Add-Member -NotePropertyName $key -NotePropertyValue $chosen -Force
        }
        if ($null -eq $data.PSObject.Properties['protected_paths']) {
            $data | Add-Member -NotePropertyName 'protected_paths' -NotePropertyValue @() -Force
        }
        $json = $data | ConvertTo-Json -Depth 10
        if (-not $json.EndsWith("`n")) {
            $json = $json + "`n"
        }
        Write-Utf8NoBom $configFile $json
        Write-Host "Generated config: $configFile"
    }

    $authFile = Join-Path $ConfigDir 'authorizations.md'
    $authTemplate = Join-Path $TemplatesDir 'authorizations.example.md'
    if (Test-PathEntry $authFile) {
        Write-Host "Preserved existing: $authFile"
    } else {
        if (-not [System.IO.File]::Exists($authTemplate)) {
            Stop-WithError "Authorization template not found: $authTemplate"
        }
        Copy-Item -LiteralPath $authTemplate -Destination $authFile -Force
        Write-Host "Generated authorization record: $authFile"
    }
}

function Append-ProjectSnippet([string]$ClaudeFile) {
    $snippetFile = Join-Path $TemplatesDir 'CLAUDE.md.snippet'
    if (-not [System.IO.File]::Exists($snippetFile)) {
        Stop-WithError "CLAUDE.md snippet not found: $snippetFile"
    }

    $bytes = New-Object byte[] 0
    if (Test-PathEntry $ClaudeFile) {
        $item = Get-Item -LiteralPath $ClaudeFile -Force -ErrorAction Stop
        if ($item -is [System.IO.DirectoryInfo]) {
            Stop-WithError "$ClaudeFile exists but is not a regular file."
        }
        $bytes = [System.IO.File]::ReadAllBytes($ClaudeFile)
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.IndexOf('agent-orchestration:begin', [System.StringComparison]::Ordinal) -ge 0) {
        Write-Host "Preserved existing: $ClaudeFile (already contains the agent-orchestration snippet)"
        return
    }

    $snippetBytes = [System.IO.File]::ReadAllBytes($snippetFile)

    # Make sure the existing content ends with a newline and there is one
    # blank line before the appended section. All changes are byte-level so
    # non-ASCII content never passes through the local code page.
    $prefix = New-Object System.Collections.Generic.List[byte]
    if ($bytes.Length -gt 0) {
        if ($bytes[$bytes.Length - 1] -ne 10) {
            $prefix.Add(10)
        }
        $lastOne = -1
        $lastTwo = -1
        if ($prefix.Count -ge 1) {
            $lastOne = 10
        } else {
            $lastOne = [int]$bytes[$bytes.Length - 1]
        }
        if ($prefix.Count -ge 2) {
            $lastTwo = 10
        } elseif ($prefix.Count -eq 1) {
            $lastTwo = [int]$bytes[$bytes.Length - 1]
        } elseif ($bytes.Length -ge 2) {
            $lastTwo = [int]$bytes[$bytes.Length - 2]
        }
        if (-not (($lastOne -eq 10) -and ($lastTwo -eq 10))) {
            $prefix.Add(10)
        }
    }

    $combined = New-Object byte[] ($bytes.Length + $prefix.Count + $snippetBytes.Length)
    if ($bytes.Length -gt 0) {
        [System.Array]::Copy($bytes, 0, $combined, 0, $bytes.Length)
    }
    if ($prefix.Count -gt 0) {
        $prefix.CopyTo($combined, $bytes.Length)
    }
    [System.Array]::Copy($snippetBytes, 0, $combined, $bytes.Length + $prefix.Count, $snippetBytes.Length)
    [System.IO.File]::WriteAllBytes($ClaudeFile, $combined)
    Write-Host "Appended CLAUDE.md snippet: $ClaudeFile"
}

function Initialize-Project([string]$ProjectDir) {
    if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
        Stop-WithError 'Project directory must not be empty.'
    }

    $workDir = Join-Path $ProjectDir 'work'
    $outputsDir = Join-Path $ProjectDir 'outputs'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    New-Item -ItemType Directory -Path $outputsDir -Force | Out-Null
    Write-Host "Initialized project: $ProjectDir"

    $templateProject = Join-Path $TemplatesDir 'project'
    if ([System.IO.Directory]::Exists($templateProject)) {
        $templateRoot = (Get-Item -LiteralPath $templateProject -Force).FullName
        $files = @(Get-ChildItem -LiteralPath $templateProject -Recurse -File -Force | Sort-Object FullName)
        foreach ($sourceFile in $files) {
            $relativePath = $sourceFile.FullName.Substring($templateRoot.Length)
            $relativePath = $relativePath.TrimStart([char[]]@('\', '/'))
            $destination = Join-Path $ProjectDir $relativePath
            if (Test-PathEntry $destination) {
                Write-Host "Skipped existing file: $destination"
            } else {
                $parent = [System.IO.Path]::GetDirectoryName($destination)
                if (-not [System.IO.Directory]::Exists($parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination -Force
                Write-Host "Copied template: $destination"
            }
        }
    }

    Append-ProjectSnippet (Join-Path $ProjectDir 'CLAUDE.md')
}

function Get-SkillStatus([string]$Target, [string]$SourceDir) {
    if (Test-IsReparsePoint $Target) {
        if (Test-LinkMatches $Target $SourceDir) {
            return 'linked'
        }
        return 'occupied (link to another target)'
    }
    if ([System.IO.Directory]::Exists($Target)) {
        if ([System.IO.File]::Exists((Join-Path $Target '.agent-orchestration-copy'))) {
            return 'copied'
        }
        return 'occupied (directory)'
    }
    if (Test-PathEntry $Target) {
        return 'occupied (file)'
    }
    return 'missing'
}

function Report-SkillsFor([string]$Label, [string]$SkillsDir) {
    Write-Host ''
    Write-Host "$Label skills directory: $SkillsDir"
    $skillsRoot = Join-Path $RepoRoot 'skills'
    $sources = @(Get-ChildItem -LiteralPath $skillsRoot -Directory | Sort-Object Name)
    foreach ($source in $sources) {
        $target = Join-Path $SkillsDir $source.Name
        $status = Get-SkillStatus $target $source.FullName
        Write-Host ("  {0,-24} {1}" -f $source.Name, $status)
    }
}

function Find-Python {
    foreach ($name in @('python3', 'python')) {
        $candidates = @(Get-Command -Name $name -CommandType Application -All -ErrorAction SilentlyContinue)
        foreach ($found in $candidates) {
            $source = [string]$found.Source
            if ([string]::IsNullOrEmpty($source)) {
                continue
            }
            if ($OnWindows -and $source -match '(?i)[\\/]WindowsApps[\\/]') {
                continue
            }
            return @{ Path = $source; Prefix = @() }
        }
    }

    $pyCandidates = @(Get-Command -Name 'py' -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($py in $pyCandidates) {
        if (-not [string]::IsNullOrEmpty([string]$py.Source)) {
            return @{ Path = [string]$py.Source; Prefix = @('-3') }
        }
    }
    return $null
}

function Invoke-PythonTest([hashtable]$Python, [string]$TestFile, [string]$DisplayName) {
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($prefix in $Python.Prefix) {
        $arguments.Add([string]$prefix)
    }
    $arguments.Add('-B')
    $arguments.Add($TestFile)

    $argumentArray = $arguments.ToArray()
    $output = & $Python.Path @argumentArray 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($output)) {
        Write-Host $line
    }
    if ($code -eq 0) {
        Write-Host "Test passed: $DisplayName"
        return $true
    }
    Write-Failure "Test failed: $DisplayName"
    return $false
}

function Show-CliStatus {
    $configFile = Join-Path $ConfigDir 'config.json'
    if (-not [System.IO.File]::Exists($configFile)) {
        Write-Host ''
        Write-Host "CLI config: missing $configFile"
        return
    }

    Write-Host ''
    Write-Host "CLI config: $configFile"
    try {
        $text = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
        $data = $text | ConvertFrom-Json
    } catch {
        Write-Host '  Cannot parse config.json (invalid JSON).'
        return
    }

    $cli = $data.cli
    if ($null -eq $cli) {
        Write-Host '  config.json has no cli section.'
        return
    }
    foreach ($key in @('deepseek', 'codex', 'claude')) {
        $property = $cli.PSObject.Properties[$key]
        $value = ''
        if ($null -ne $property -and $null -ne $property.Value) {
            $value = [string]$property.Value
        }
        if ([string]::IsNullOrEmpty($value)) {
            Write-Host ("  {0,-8} empty (not found)" -f $key)
            continue
        }
        $expanded = Expand-UserPath $value
        if ([System.IO.File]::Exists($expanded)) {
            Write-Host ("  {0,-8} {1} (exists)" -f $key, $value)
        } else {
            Write-Host ("  {0,-8} {1} (missing)" -f $key, $value)
        }
    }
}

function Invoke-Check {
    $checkStatus = 0

    Write-Host '== Offline tests =='
    $python = Find-Python
    if ($null -eq $python) {
        Write-Failure 'Python 3 not found; cannot run the offline tests.'
        $checkStatus = 1
    } else {
        $workerTest = Join-Path $RepoRoot 'skills/subagent-dispatch/tests/test_worker.py'
        if ([System.IO.File]::Exists($workerTest)) {
            if (-not (Invoke-PythonTest $python $workerTest 'test_worker.py')) {
                $checkStatus = 1
            }
        } else {
            Write-Failure "Test file missing: $workerTest"
            $checkStatus = 1
        }

        $progressTest = Join-Path $RepoRoot 'skills/subagent-dispatch/tests/test_check_progress.py'
        if ([System.IO.File]::Exists($progressTest)) {
            if (-not (Invoke-PythonTest $python $progressTest 'test_check_progress.py')) {
                $checkStatus = 1
            }
        } else {
            Write-Host "Skip: test_check_progress.py not found at $progressTest"
        }
    }

    Write-Host ''
    Write-Host '== Skill status =='
    Report-SkillsFor 'Claude' $ClaudeSkillsDir
    Report-SkillsFor 'Codex' $CodexSkillsDir
    Show-CliStatus

    if ($checkStatus -eq 0) {
        Write-Host ''
        Write-Host 'Check complete: all offline tests passed.'
    } else {
        Write-Host ''
        Write-Failure 'Check complete: some offline tests failed.'
    }
    return $checkStatus
}

function Print-Summary {
    Write-Host ''
    Write-Host '===== Summary ====='

    Write-Host 'Installed/updated:'
    if ($InstalledNotes.Count -eq 0) {
        Write-Host '  (none)'
    } else {
        foreach ($note in $InstalledNotes) {
            Write-Host "  - $note"
        }
    }

    if ($SkippedNotes.Count -gt 0) {
        Write-Host 'Skipped (already at target state):'
        foreach ($note in $SkippedNotes) {
            Write-Host "  - $note"
        }
    }

    Write-Host 'Backups:'
    if ($BackupNotes.Count -eq 0) {
        Write-Host '  (none)'
    } else {
        foreach ($note in $BackupNotes) {
            Write-Host "  - $note"
        }
    }

    if ($null -ne $script:ProjectOnlyBound -and $script:ProjectOnlyBound) {
        Write-Host "Config directory: $ConfigDir (unchanged by -ProjectOnly)"
    } else {
        Write-Host "Config directory: $ConfigDir"
    }
    if (-not [string]::IsNullOrEmpty($Project)) {
        Write-Host "Project directory: $Project"
    }

    Write-Host ''
    Write-Host 'Next step: open Claude Code and run /subagent-dispatch; for a new project run .\install.ps1 -ProjectOnly <dir>'
}

if ($Help) {
    Show-Usage
    exit 0
}

if ($Copy) {
    $Mode = 'copy'
} else {
    $Mode = 'link'
}

$script:ProjectOnlyBound = $PSBoundParameters.ContainsKey('ProjectOnly')

if ($Check) {
    if ((Invoke-Check) -eq 0) {
        exit 0
    }
    exit 1
}

if ($script:ProjectOnlyBound) {
    if ([string]::IsNullOrWhiteSpace($ProjectOnly)) {
        Stop-WithError 'Project directory must not be empty.'
    }
    Initialize-Project $ProjectOnly
    $Project = $ProjectOnly
    Print-Summary
    exit 0
}

Install-Skills
Configure-AgentOrchestration
if (-not [string]::IsNullOrEmpty($Project)) {
    Initialize-Project $Project
}
Print-Summary
