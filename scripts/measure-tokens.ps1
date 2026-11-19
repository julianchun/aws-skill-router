# This runs `claude -p` 9 times (3 environments x 3 runs) and costs a small amount of API usage.
[CmdletBinding()]
param(
    [string]$SkillsDir,
    [string[]]$Skills,
    [int]$Runs = 3,
    [switch]$IncludeUserConfig,
    [switch]$Keep,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Exit-WithError {
    param([string]$Message)
    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}

if ($SkillsDir -and $Skills -and $Skills.Count -gt 0) {
    Exit-WithError "-SkillsDir and -Skills cannot be used together."
}

if ($Runs -lt 1) {
    Exit-WithError "-Runs must be at least 1."
}

$mult = [char]0x00D7
$totalCalls = $Runs * 3
Write-Host "This runs ``claude -p`` $totalCalls times (3 environments $mult $Runs runs) and costs a small amount of API usage."
if ($IncludeUserConfig) {
    Write-Host "Settings mode: including user config (default Claude Code setting sources)"
} else {
    Write-Host "Settings mode: isolated (--setting-sources project,local)"
}

if (-not $Yes) {
    try {
        $answer = Read-Host "Continue? [y/N]"
    } catch {
        $answer = ''
    }
    if ($answer -notin @('y', 'Y', 'yes', 'YES')) {
        Write-Host "Aborted."
        exit 0
    }
}

function Assert-CommandExists {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Assert-AwsCliVersion {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        throw "AWS CLI not found. Install AWS CLI >= 2.35.0."
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $verOutput = (& aws --version 2>&1 | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($verOutput -notmatch 'aws-cli/((\d+)\.(\d+)(?:\.\S*)?)(?:\s|$)') {
        throw "Could not parse AWS CLI version from: $verOutput"
    }
    $ver = $Matches[1]
    $major = [int]$Matches[2]
    $minor = [int]$Matches[3]
    if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 35)) {
        throw "AWS CLI >= 2.35.0 is required (found aws-cli/$ver)."
    }
}

function Get-RouterSkillNames {
    param([string]$SkillFile)
    $lines = [IO.File]::ReadAllLines($SkillFile, [Text.Encoding]::UTF8)
    $inSection = $false
    $foundSection = $false
    $seenSep = $false
    $names = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if ($line -match '^## Frequently used skill names\s*$') {
            $inSection = $true
            $foundSection = $true
            continue
        }
        if ($inSection -and $line -match '^## ') {
            $inSection = $false
            continue
        }
        if ($inSection -and $line -match '^\|') {
            if ($line -match '^\|(\s*:?-+:?\s*\|)+\s*$') {
                $seenSep = $true
                continue
            }
            if (-not $seenSep) {
                continue
            }
            $cells = $line -split '\|'
            $cell = ''
            for ($i = $cells.Length - 1; $i -ge 0; $i--) {
                if ($cells[$i] -match '\S') {
                    $cell = $cells[$i]
                    break
                }
            }
            foreach ($m in [regex]::Matches($cell, '`([^`]+)`')) {
                $tok = $m.Groups[1].Value
                if ($tok -match '^[a-z0-9]+(-[a-z0-9]+)*$') {
                    $names.Add($tok)
                }
            }
        }
    }

    if (-not $foundSection -or -not $seenSep) {
        throw ('Table "## Frequently used skill names" not found in ' + $SkillFile)
    }
    $unique = @($names | Select-Object -Unique | Sort-Object)
    if ($unique.Count -eq 0) {
        throw "Zero skill names extracted from $SkillFile"
    }
    return $unique
}

function Get-JsonProp {
    param(
        [object]$Obj,
        [string]$Name
    )
    if ($null -eq $Obj) {
        return $null
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }
    return $prop.Value
}

function Get-UsageInt {
    param(
        [object]$Usage,
        [string]$Name
    )
    $val = Get-JsonProp -Obj $Usage -Name $Name
    if ($null -eq $val) {
        return [long]0
    }
    return [long]$val
}

function Invoke-EnvMeasurement {
    param(
        [string]$Label,
        [string]$WorkDir,
        [string]$TempRoot,
        [int]$RunCount,
        [switch]$IncludeUserConfig
    )
    $totals = New-Object System.Collections.Generic.List[long]
    $claudeArgs = @('-p', 'Reply with exactly: OK', '--output-format', 'json', '--max-turns', '1')
    if (-not $IncludeUserConfig) {
        $claudeArgs += @('--setting-sources', 'project,local')
    }

    Push-Location -LiteralPath $WorkDir
    try {
        for ($i = 1; $i -le $RunCount; $i++) {
            Write-Host "Running $Label ($i/$RunCount)..."
            $errFile = Join-Path $TempRoot "${Label}_run_${i}.err"
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $rawLines = & claude @claudeArgs 2> $errFile
                $rc = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
            }

            $rawJson = if ($null -ne $rawLines) { ($rawLines -join "`n") } else { '' }

            if ($rc -ne 0) {
                $errText = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw } else { '' }
                throw "claude exited with status $rc in $Label (run $i).`n--- stderr ---`n$errText`n--- stdout ---`n$rawJson"
            }

            try {
                $parsed = $rawJson | ConvertFrom-Json
            } catch {
                throw "Failed to parse JSON from claude output in $Label (run $i): $_`n--- stdout ---`n$rawJson"
            }

            if ($null -eq $parsed -or $parsed -isnot [PSCustomObject]) {
                throw "Failed to parse JSON object from claude output in $Label (run $i).`n--- stdout ---`n$rawJson"
            }

            $resultVal = Get-JsonProp -Obj $parsed -Name 'result'
            if ($null -eq $resultVal) {
                $resultVal = Get-JsonProp -Obj $parsed -Name 'error'
            }
            $resultText = if ($null -eq $resultVal) {
                ''
            } elseif ($resultVal -is [string]) {
                $resultVal
            } else {
                ($resultVal | ConvertTo-Json -Compress)
            }

            $isError = Get-JsonProp -Obj $parsed -Name 'is_error'
            if ($isError -is [bool] -and $isError) {
                $detail = if ($resultText) { $resultText } else { 'unknown error' }
                throw "claude returned an error in $Label (run $i): $detail`n--- stdout ---`n$rawJson"
            }

            $subtype = Get-JsonProp -Obj $parsed -Name 'subtype'
            if ($subtype -isnot [string] -or $subtype -cne 'success') {
                $gotSubtype = if ($null -eq $subtype -or "$subtype" -eq '') { '<missing>' } else { "$subtype" }
                $suffix = if ($resultText) { ": $resultText" } else { '' }
                throw "claude did not return subtype `"success`" (got `"$gotSubtype`") in $Label (run $i)$suffix`n--- stdout ---`n$rawJson"
            }

            $u = Get-JsonProp -Obj $parsed -Name 'usage'
            if ($null -eq $u -or $u -isnot [PSCustomObject]) {
                $suffix = if ($resultText) { ": $resultText" } else { '' }
                throw "JSON output from claude in $Label (run $i) lacks .usage object$suffix`n--- stdout ---`n$rawJson"
            }

            $total = (Get-UsageInt -Usage $u -Name 'input_tokens') +
                     (Get-UsageInt -Usage $u -Name 'cache_creation_input_tokens') +
                     (Get-UsageInt -Usage $u -Name 'cache_read_input_tokens')
            if ($total -le 0) {
                $suffix = if ($resultText) { ": $resultText" } else { '' }
                throw "claude returned $total prompt tokens in $Label (run $i)$suffix`n--- stdout ---`n$rawJson"
            }
            $totals.Add($total)
        }
    } finally {
        Pop-Location
    }

    return @($totals)
}

function Get-Median {
    param([long[]]$Values)
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) {
        throw "Cannot compute median of empty list."
    }
    if (($n % 2) -eq 1) {
        return [long]$sorted[[int](($n - 1) / 2)]
    }
    $midA = [long]$sorted[[int]($n / 2) - 1]
    $midB = [long]$sorted[[int]($n / 2)]
    $sum = $midA + $midB + 1
    return [long](($sum - ($sum % 2)) / 2)
}

function Test-Variance {
    param(
        [string]$Label,
        [long[]]$Values
    )
    $sorted = @($Values | Sort-Object)
    if ($sorted[0] -ne $sorted[$sorted.Count - 1]) {
        Write-Warning "Run totals differed within $Label (min=$($sorted[0]), max=$($sorted[$sorted.Count - 1]))."
    }
}

Assert-CommandExists -Name 'claude'
Assert-CommandExists -Name 'git'

if (-not $SkillsDir) {
    Assert-AwsCliVersion
} elseif (-not (Test-Path -LiteralPath $SkillsDir -PathType Container)) {
    throw "-SkillsDir does not exist or is not a directory: $SkillsDir"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$routerSkillDir = Join-Path (Join-Path $repoRoot 'skills') 'aws'
$routerSkillMd = Join-Path $routerSkillDir 'SKILL.md'

if (-not (Test-Path -LiteralPath $routerSkillMd -PathType Leaf)) {
    throw "Router SKILL.md not found: $routerSkillMd"
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("aws-skill-router-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot | Out-Null

try {
    foreach ($envName in @('A-baseline', 'B-official', 'C-router')) {
        $envPath = Join-Path $tmpRoot $envName
        New-Item -ItemType Directory -Path $envPath | Out-Null
        Push-Location -LiteralPath $envPath
        try {
            & git init -q
            if ($LASTEXITCODE -ne 0) {
                throw "git init failed in $envPath"
            }
        } finally {
            Pop-Location
        }
    }

    # Populate B-official
    $bSkillsDir = Join-Path (Join-Path (Join-Path $tmpRoot 'B-official') '.claude') 'skills'
    New-Item -ItemType Directory -Path $bSkillsDir -Force | Out-Null

    if ($SkillsDir) {
        $subDirs = @(Get-ChildItem -LiteralPath $SkillsDir -Force -Directory)
        foreach ($d in $subDirs) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'SKILL.md') -PathType Leaf) {
                Copy-Item -LiteralPath $d.FullName -Destination (Join-Path $bSkillsDir $d.Name) -Recurse
            }
        }
    } else {
        if ($Skills -and $Skills.Count -gt 0) {
            $skillList = @(
                ($Skills -join ',') -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne '' } |
                Select-Object -Unique |
                Sort-Object
            )
            if ($skillList.Count -eq 0) {
                throw "-Skills produced an empty list."
            }
        } else {
            $skillList = @(Get-RouterSkillNames -SkillFile $routerSkillMd)
        }

        $fakeHome = Join-Path $tmpRoot 'home'
        New-Item -ItemType Directory -Path (Join-Path $fakeHome '.claude') -Force | Out-Null

        $origHome = $env:HOME
        $origUserProfile = $env:USERPROFILE
        try {
            $env:HOME = $fakeHome
            $env:USERPROFILE = $fakeHome

            foreach ($skillName in $skillList) {
                Write-Host "Installing official skill: $skillName"
                & aws agent-toolkit add-skill --skill-name $skillName --agent claude-code --region us-east-1 --no-sign-request
                if ($LASTEXITCODE -ne 0) {
                    throw "aws agent-toolkit add-skill failed for '$skillName' (exit code $LASTEXITCODE)."
                }
            }
        } finally {
            if ($null -eq $origHome) {
                Remove-Item Env:HOME -ErrorAction SilentlyContinue
            } else {
                $env:HOME = $origHome
            }
            if ($null -eq $origUserProfile) {
                Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue
            } else {
                $env:USERPROFILE = $origUserProfile
            }
        }

        $installedDir = Join-Path (Join-Path $fakeHome '.claude') 'skills'
        $missingSkills = New-Object System.Collections.Generic.List[string]
        foreach ($skillName in $skillList) {
            $expectedSkillMd = Join-Path (Join-Path $installedDir $skillName) 'SKILL.md'
            if (-not (Test-Path -LiteralPath $expectedSkillMd -PathType Leaf)) {
                $missingSkills.Add($skillName)
            }
        }
        if ($missingSkills.Count -gt 0) {
            $missingList = ($missingSkills | ForEach-Object { "  $_" }) -join "`n"
            throw "add-skill did not install SKILL.md for requested skill(s):`n$missingList"
        }

        if (Test-Path -LiteralPath $installedDir -PathType Container) {
            $installedSubDirs = @(Get-ChildItem -LiteralPath $installedDir -Force -Directory)
            foreach ($d in $installedSubDirs) {
                if (Test-Path -LiteralPath (Join-Path $d.FullName 'SKILL.md') -PathType Leaf) {
                    Copy-Item -LiteralPath $d.FullName -Destination (Join-Path $bSkillsDir $d.Name) -Recurse
                }
            }
        }
    }

    $bSkillCount = @(
        @(Get-ChildItem -LiteralPath $bSkillsDir -Force -Directory) |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf }
    ).Count

    if ($bSkillCount -eq 0) {
        throw "B-official contains 0 skills."
    }
    Write-Host "B-official contains $bSkillCount skill(s)."

    # Populate C-router
    $cSkillsParent = Join-Path (Join-Path (Join-Path $tmpRoot 'C-router') '.claude') 'skills'
    New-Item -ItemType Directory -Path $cSkillsParent -Force | Out-Null
    $routerDest = Join-Path $cSkillsParent 'aws-router-test'
    Copy-Item -LiteralPath $routerSkillDir -Destination $routerDest -Recurse

    $routerCopyMd = Join-Path $routerDest 'SKILL.md'
    $lines = [IO.File]::ReadAllLines($routerCopyMd, [Text.Encoding]::UTF8)
    $inFrontmatter = $false
    $replaced = $false
    $outLines = New-Object System.Collections.Generic.List[string]

    for ($idx = 0; $idx -lt $lines.Length; $idx++) {
        $line = $lines[$idx]
        if ($idx -eq 0 -and $line -match '^---\s*$') {
            $inFrontmatter = $true
            $outLines.Add($line)
            continue
        }
        if ($inFrontmatter -and $line -match '^---\s*$') {
            $inFrontmatter = $false
            $outLines.Add($line)
            continue
        }
        if ($inFrontmatter -and (-not $replaced) -and $line -match '^name:\s*aws\s*$') {
            $outLines.Add('name: aws-router-test')
            $replaced = $true
            continue
        }
        $outLines.Add($line)
    }

    if (-not $replaced) {
        throw "Failed to rewrite 'name: aws' in frontmatter of $routerCopyMd"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($routerCopyMd, (($outLines -join "`n") + "`n"), $utf8NoBom)

    # Measure all three environments
    $aTotals = [long[]]@(Invoke-EnvMeasurement -Label 'A-baseline' -WorkDir (Join-Path $tmpRoot 'A-baseline') -TempRoot $tmpRoot -RunCount $Runs -IncludeUserConfig:$IncludeUserConfig)
    $bTotals = [long[]]@(Invoke-EnvMeasurement -Label 'B-official' -WorkDir (Join-Path $tmpRoot 'B-official') -TempRoot $tmpRoot -RunCount $Runs -IncludeUserConfig:$IncludeUserConfig)
    $cTotals = [long[]]@(Invoke-EnvMeasurement -Label 'C-router'   -WorkDir (Join-Path $tmpRoot 'C-router')   -TempRoot $tmpRoot -RunCount $Runs -IncludeUserConfig:$IncludeUserConfig)

    $medA = Get-Median -Values $aTotals
    $medB = Get-Median -Values $bTotals
    $medC = Get-Median -Values $cTotals

    $diffBA = $medB - $medA
    $diffCA = $medC - $medA
    $diffBC = $medB - $medC

    Write-Host ""
    Write-Host ("{0,-14} | {1,-30} | {2}" -f "Environment", "Per-run prompt tokens", "Median")
    Write-Host ("{0,-14}-+-{1,-30}-+-{2}" -f ("-" * 14), ("-" * 30), ("-" * 10))
    Write-Host ("{0,-14} | {1,-30} | {2}" -f "A-baseline", ($aTotals -join ", "), $medA)
    Write-Host ("{0,-14} | {1,-30} | {2}" -f "B-official", ($bTotals -join ", "), $medB)
    Write-Host ("{0,-14} | {1,-30} | {2}" -f "C-router",   ($cTotals -join ", "), $medC)
    Write-Host ""
    Write-Host "Official skills overhead (B - A): $diffBA tokens ($bSkillCount skills)"
    Write-Host "Router overhead          (C - A): $diffCA tokens"
    Write-Host "Net saving per request   (B - C): $diffBC tokens"

    Test-Variance -Label 'A-baseline' -Values $aTotals
    Test-Variance -Label 'B-official' -Values $bTotals
    Test-Variance -Label 'C-router'   -Values $cTotals
} finally {
    if ($Keep) {
        Write-Host "Kept temporary directory: $tmpRoot"
    } elseif (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
