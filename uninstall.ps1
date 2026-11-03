# Uninstall agent-orchestration skills owned by this repository on Windows.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.
# This file must stay ASCII-only.

[CmdletBinding()]
param(
    [switch]$Purge,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$ScriptPath = $PSCommandPath
if ([string]::IsNullOrEmpty($ScriptPath)) {
    $ScriptPath = $MyInvocation.MyCommand.Path
}
$ScriptFull = [System.IO.Path]::GetFullPath($ScriptPath)
$RepoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $ScriptFull))

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

function Show-Usage {
    Write-Host 'Usage: .\uninstall.ps1 [options]'
    Write-Host ''
    Write-Host 'Removes only links that point into this repository and copy'
    Write-Host 'directories carrying the .agent-orchestration-copy marker, in both'
    Write-Host 'the Claude and Codex skills directories. Everything else is left'
    Write-Host 'alone. The configuration directory is kept unless -Purge is given.'
    Write-Host ''
    Write-Host 'Options:'
    Write-Host '  -Purge       Also remove the configuration directory'
    Write-Host '  -Help        Show this help'
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

function Get-NormalizedFullPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $full.TrimEnd($trimChars)
}

function Test-PathEquals([string]$Left, [string]$Right) {
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        return ($Left -ceq $Right)
    }
    return ($Left -eq $Right)
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
    return (Test-PathEquals $target (Get-NormalizedFullPath $SourceDir))
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

function Remove-FromSkillsDir([string]$Label, [string]$SkillsDir) {
    if (-not [System.IO.Directory]::Exists($SkillsDir)) {
        return
    }

    $skillsRoot = Join-Path $RepoRoot 'skills'
    if (-not [System.IO.Directory]::Exists($skillsRoot)) {
        return
    }
    $sources = @(Get-ChildItem -LiteralPath $skillsRoot -Directory | Sort-Object Name)
    foreach ($source in $sources) {
        $target = Join-Path $SkillsDir $source.Name
        if (Test-IsReparsePoint $target) {
            if (Test-LinkMatches $target $source.FullName) {
                Remove-LinkEntry $target
                Write-Host "Removed $Label link: $target"
            } else {
                Write-Host "Preserved $Label (not a link to this repository): $target"
            }
        } elseif ([System.IO.Directory]::Exists($target)) {
            if ([System.IO.File]::Exists((Join-Path $target '.agent-orchestration-copy'))) {
                Remove-Item -LiteralPath $target -Recurse -Force
                Write-Host "Removed $Label copy directory: $target"
            } else {
                Write-Host "Preserved $Label (not installed by this script): $target"
            }
        } elseif (Test-PathEntry $target) {
            Write-Host "Preserved $Label (not installed by this script): $target"
        }
    }
}

function Test-SafePurgePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if ($Path -eq '.' -or $Path -eq '..' -or $Path -eq '/' -or $Path -eq '\') {
        return $false
    }

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }

    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $trimmed = $full.TrimEnd($trimChars)
    if ([string]::IsNullOrEmpty($trimmed)) {
        return $false
    }

    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not [string]::IsNullOrEmpty($root)) {
        $rootTrimmed = $root.TrimEnd($trimChars)
        if ($trimmed -eq $rootTrimmed) {
            return $false
        }
    }

    foreach ($protected in @($HomeDir, $RepoRoot)) {
        if ([string]::IsNullOrEmpty($protected)) {
            continue
        }
        try {
            $protectedFull = (Get-NormalizedFullPath $protected)
        } catch {
            continue
        }
        if (Test-PathEquals $trimmed $protectedFull) {
            return $false
        }
    }
    return $true
}

if ($Help) {
    Show-Usage
    exit 0
}

Remove-FromSkillsDir 'Claude' $ClaudeSkillsDir
Remove-FromSkillsDir 'Codex' $CodexSkillsDir

if ($Purge) {
    if (-not (Test-SafePurgePath $ConfigDir)) {
        Stop-WithError "Refusing to delete an unsafe config path: $ConfigDir"
    }
    if (Test-PathEntry $ConfigDir) {
        if (Test-IsReparsePoint $ConfigDir) {
            Remove-LinkEntry $ConfigDir
        } else {
            Remove-Item -LiteralPath $ConfigDir -Recurse -Force
        }
        Write-Host "Removed config directory: $ConfigDir"
    } else {
        Write-Host "Config directory does not exist: $ConfigDir"
    }
} else {
    Write-Host "Config directory preserved: $ConfigDir"
}
