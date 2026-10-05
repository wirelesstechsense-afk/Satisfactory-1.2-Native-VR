<#
.SYNOPSIS
    NativeVR setup for Satisfactory 1.2: brings Epic's VR Template, plus every
    plugin it needs, out of the CSS 5.6.1 engine source and into your SML
    starter project as mods. Then it builds the editor and sets the project up
    for Claude Code.

.DESCRIPTION
    What it does, in order:
      1. Checks your project, your CSS engine install and git.
      2. Downloads ONLY the parts it needs from the CSS engine repo on GitHub
         (a "sparse" download: the VR Template folder and the plugin folders,
         not the whole 100+ GB engine). Template art and maps are not stored in
         git, so it pulls just those files from Epic's download server the same
         way the engine's own Setup.bat does.
      3. Reads the VR Template's project file and scans its assets to work out
         which plugins it really uses. Any plugin your CSS install lacks is
         fetched from source and placed in Mods as its own mod (Epic's code is
         copied unchanged; only the mod descriptor gets SML fields added).
      4. Copies the template's content into the project's Content folder,
         together with the shared content packs Epic's project wizard adds
         with it (LevelPrototyping, Weapons, VRSpectator: the floor, cubes and
         pistol mesh). It stays there as NativeVR's test bed. Only the asset
         files are copied: Epic's packs also hold source art (FBX), which the
         editor's auto reimport would offer to import over the meshes. Adds the
         template's input mapping contexts to Config\DefaultInput.ini, which
         OpenXR needs to bind the controller buttons. Creates the NativeVR mod
         that depends on those plugins (and on NativeVRCore, if present).
      5. Fixes the template for FactoryGame: FactoryGame turns baked lighting
         off, so the template map's baked lights (the campfire light, a fill
         light and the sky light) are switched to Movable.
      6. Writes CLAUDE.md and .claude\settings.json so Claude Code knows the
         project, your rules and the plan, and is blocked from editing the
         engine install.
      7. Builds the FactoryEditor target. Then it runs the editor once without
         a window to do two things only the editor can: save the template's
         grid material with "Used with Nanite" and create the NativeVR data
         asset (FGGameFeatureData). Writes a report.

    It never writes to the engine install. The first run is a clean start:
    old copies of Epic's plugins and template from earlier attempts are moved
    to _NativeVR_Backup\<time>, never deleted. Your own NativeVR and
    NativeVRCore mods (for example from the GitHub repo) are never moved; the
    script only adds what NativeVR's .uplugin is missing. Later runs only ADD
    what is missing and leave your NativeVR work, the plugin mods and
    CLAUDE.md alone (-Fresh starts over instead; modules that were added to
    Epic's plugins for NativeVR, such as a missing third-party or engine
    module, are carried over from the old copy).
    -FreshTemplate replaces only the template content in Content with a clean
    copy (the old one goes to _NativeVR_Backup) and leaves everything else.

    Engine modules your CSS install has only as source (not compiled), such
    as the LiveLink modules hand tracking needs, are copied unchanged into
    the mod that uses them and added to its .uplugin. The OpenXR SDK (Khronos'
    headers and loader), which the CSS install leaves out entirely, goes into
    the OpenXR mod with its build rules pointed at the mod's folder. Epic's
    plugins that the CSS install also keeps as source only get a higher
    version number in their mod's .uplugin, so the editor loads the mod and
    not the engine copy.
    -SkipPlugins A,B leaves plugins out (for example OpenXRHandTracking).

    If a download fails, nothing in the project has been touched yet; just run
    it again and it carries on from what it already downloaded.

    Run it as a file (below) or paste this whole file into PowerShell; both work.
    Options: -ProjectDir -EngineDir -SourceDir -CacheDir -RepoUrl -Branch
             -ModName -ExtraPlugins A,B -SkipPlugins A,B -Fresh -FreshTemplate
             -SkipBuild -NoPause

.EXAMPLE
    # From any PowerShell window (the script finds the project folder itself):
    powershell -ExecutionPolicy Bypass -File "C:\SatisfactoryModLoader\Setup-NativeVR.ps1"

.EXAMPLE
    # Replace the template content with a clean copy (close the editor first):
    powershell -ExecutionPolicy Bypass -File "C:\SatisfactoryModLoader\Setup-NativeVR.ps1" -FreshTemplate

.EXAMPLE
    # Add a plugin the template turned out to need, without re-downloading the rest:
    powershell -ExecutionPolicy Bypass -File "C:\SatisfactoryModLoader\Setup-NativeVR.ps1" -ExtraPlugins XRVisualization
#>
$NativeVRResult = @(& {
param([object[]]$Argv)

# ----------------------------------------------------------------- options ---
# The whole script lives inside this one block, so it behaves the same whether the file is run
# (powershell -File ...) or its contents are pasted into a PowerShell window.
$ProjectDir = ''
$EngineDir = ''
$SourceDir = ''
$CacheDir = 'C:\NativeVR-Source'
$RepoUrl = 'https://github.com/satisfactorymodding/UnrealEngine.git'
$Branch = ''
$ModName = 'NativeVR'
$ExtraPlugins = @()
# Plugins the template enables that NativeVR should leave out. Empty: hand and eye tracking come in too, with the
# LiveLink modules they need. -SkipPlugins replaces this list (-SkipPlugins none skips nothing); -ExtraPlugins wins.
$SkipPlugins = @()
$SkipPluginsGiven = $false
$Fresh = $false
$FreshTemplate = $false
$SkipBuild = $false
$NoPause = $false
$RunningAsFile = [bool]$PSCommandPath
$Argv = @($Argv | Where-Object { $null -ne $_ })
for ($ai = 0; $ai -lt $Argv.Count; $ai++) {
    $a = [string]$Argv[$ai]
    if ($a -match '^-(Fresh|FreshTemplate|SkipBuild|NoPause)$') { Set-Variable -Name $Matches[1] -Value $true; continue }
    if ($a -match '^-(ProjectDir|EngineDir|SourceDir|CacheDir|RepoUrl|Branch|ModName|ExtraPlugins|SkipPlugins)$') {
        $key = $Matches[1]
        if ($ai + 1 -ge $Argv.Count) { Write-Host "Option $a needs a value after it." -ForegroundColor Red; return 2 }
        $ai++
        if ($key -eq 'ExtraPlugins' -or $key -eq 'SkipPlugins') {
            $vals = @()
            foreach ($v in @($Argv[$ai])) { $vals += @("$v" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'none' }) }
            if ($key -eq 'ExtraPlugins') { $ExtraPlugins += $vals }
            else {
                if (-not $SkipPluginsGiven) { $SkipPlugins = @(); $SkipPluginsGiven = $true }
                $SkipPlugins += $vals
            }
        } else { Set-Variable -Name $key -Value ([string]$Argv[$ai]) }
        continue
    }
    Write-Host "Unknown option: $a" -ForegroundColor Red
    Write-Host 'Options: -ProjectDir -EngineDir -SourceDir -CacheDir -RepoUrl -Branch -ModName -ExtraPlugins A,B -SkipPlugins A,B -Fresh -FreshTemplate -SkipBuild -NoPause'
    return 2
}
if (-not $CacheDir) { $CacheDir = 'C:\NativeVR-Source' }


$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# Shared state for the helper functions below (kept inside this block, so nothing leaks into your PowerShell window).
$S = @{ Warnings = (New-Object System.Collections.Generic.List[string]); BackupRoot = $null; LastStderr = $null; LastExit = 0 }
$Sep = [System.IO.Path]::DirectorySeparatorChar

# ---------------------------------------------------------------- helpers ---

function Say([string]$m) { Write-Host $m }
function Step([string]$m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "    OK  $m" -ForegroundColor Green }
function Note([string]$m) { Write-Host "    ..  $m" }
function Warn([string]$m) { Write-Host "    !!  $m" -ForegroundColor Yellow; $S.Warnings.Add($m) }

function P { return [System.IO.Path]::Combine([string[]]$args) }

# Walks up from a folder until it finds FactoryGame.uproject (so any folder inside the project works).
function Find-ProjectRoot([string]$Start) {
    if (-not $Start) { return $null }
    try { $d = (Resolve-Path -LiteralPath $Start -ErrorAction Stop).Path } catch { return $null }
    while ($d) {
        if (Test-Path -LiteralPath (P $d 'FactoryGame.uproject')) { return $d.TrimEnd($Sep) }
        $parent = Split-Path -Parent $d
        if (-not $parent -or $parent -eq $d) { break }
        $d = $parent
    }
    return $null
}

# Last resort: look one level under each drive root and in Documents\Unreal Projects.
function Find-ProjectByScan {
    if (-not $OnWindows) { return $null }
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($drv in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($drv.Root -match '^[A-Za-z]:\\$' -and -not $drv.DisplayRoot) { $roots.Add($drv.Root) }
    }
    $roots.Add((P $HOME 'Documents' 'Unreal Projects'))
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        foreach ($sub in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (P $sub.FullName 'FactoryGame.uproject')) { $hits.Add($sub.FullName) }
        }
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    if ($hits.Count -gt 1 -and (Test-Interactive)) {
        Write-Host 'Found more than one starter project:'
        for ($i = 0; $i -lt $hits.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $hits[$i]) }
        $pick = Read-Host 'Type the number of the one to use'
        $n = 0
        if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $hits.Count) { return $hits[$n - 1] }
    }
    if ($hits.Count -gt 1) { throw ("Found several starter projects; run again with -ProjectDir and one of these:`n  {0}" -f ($hits -join "`n  ")) }
    return $null
}

function Test-Interactive {
    try { return (-not [Console]::IsInputRedirected) } catch { return $false }
}

# Keeps the window open when the script was started from Explorer (right-click > Run with PowerShell),
# which otherwise closes the window the moment the script ends.
function Wait-BeforeClose {
    if (-not $RunningAsFile -or $NoPause -or -not $OnWindows -or -not (Test-Interactive)) { return }
    $parent = ''
    try {
        $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
        $parent = (Get-Process -Id $ppid -ErrorAction Stop).ProcessName
    } catch { }
    if ($parent -eq 'explorer') { Write-Host ''; [void](Read-Host 'Press Enter to close this window') }
}
function As-Array($x) { if ($null -eq $x) { return ,@() } return ,@($x) }
function New-Set { return ,([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)) }
function To-Native([string]$rel) { return $rel.Replace('/', $Sep) }

function Write-TextFile([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}
function Read-Json([string]$Path) { return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json) }
# Writes JSON the way Unreal's own .uplugin files look (tabs). Self-contained, so it behaves the same in
# Windows PowerShell 5.1 and PowerShell 7 (5.1's ConvertTo-Json can mangle arrays).
function Quote-Json([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append('\\') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9) { [void]$sb.Append('\t') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function ConvertTo-UeJson($Value, [int]$Depth = 0) {
    $pad = "`t" * ($Depth + 1)
    $end = "`t" * $Depth
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [enum]) { return (Quote-Json ([string]$Value)) }
    if ($Value -is [System.ValueType]) { return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    $parts = New-Object System.Collections.Generic.List[string]
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) { $parts.Add($pad + (Quote-Json ([string]$k)) + ': ' + (ConvertTo-UeJson $Value[$k] ($Depth + 1))) }
        if ($parts.Count -eq 0) { return '{}' }
        return "{`r`n" + ($parts -join ",`r`n") + "`r`n$end}"
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) {
            if ($p.MemberType -ne 'NoteProperty') { continue }
            $parts.Add($pad + (Quote-Json $p.Name) + ': ' + (ConvertTo-UeJson $p.Value ($Depth + 1)))
        }
        if ($parts.Count -eq 0) { return '{}' }
        return "{`r`n" + ($parts -join ",`r`n") + "`r`n$end}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($x in $Value) { $parts.Add($pad + (ConvertTo-UeJson $x ($Depth + 1))) }
        if ($parts.Count -eq 0) { return '[]' }
        return "[`r`n" + ($parts -join ",`r`n") + "`r`n$end]"
    }
    return (Quote-Json ([string]$Value))
}
function Save-Json($Obj, [string]$Path) { Write-TextFile $Path ((ConvertTo-UeJson $Obj) + "`r`n") }
function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}
function Set-Prop($Obj, [string]$Name, $Value) {
    if ($Obj.PSObject.Properties[$Name]) { $Obj.$Name = $Value }
    else { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}
function Remove-Prop($Obj, [string]$Name) { if ($Obj.PSObject.Properties[$Name]) { $Obj.PSObject.Properties.Remove($Name) } }

# Runs a program and returns its normal output lines. Error-stream text is kept in $S.LastStderr.
function Invoke-Native([string]$Exe, [string[]]$Arguments, [switch]$AllowFail) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = & $Exe @Arguments 2>&1 } finally { $ErrorActionPreference = $old }
    $code = $LASTEXITCODE
    $out = New-Object System.Collections.Generic.List[string]
    $err = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($raw)) {
        if ($r -is [System.Management.Automation.ErrorRecord]) {
            $t = "$r"
            if ($t -and $t -ne 'System.Management.Automation.RemoteException') { $err.Add($t) }
        } elseif ($null -ne $r) { $out.Add("$r") }
    }
    $S.LastStderr = $err
    $S.LastExit = $code
    if (-not $AllowFail -and $code -ne 0) {
        $tail = (@($err) + @($out) | Select-Object -Last 15) -join "`n"
        throw ("Command failed (exit {0}): {1} {2}`n{3}" -f $code, $Exe, ($Arguments -join ' '), $tail)
    }
    return $out.ToArray()
}

# Runs git with its progress shown live (used for the slow download steps).
function Invoke-GitLive([string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git @Arguments | Out-Host } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE). Scroll up for git's message." }
}

# Writes one file from the git download to disk byte-for-byte (fetching it if needed).
function Save-GitBlob([string]$Repo, [string]$RelPath, [string]$Dest) {
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ('-C "{0}" cat-file blob "HEAD:{1}"' -f $Repo, $RelPath)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $fs = [System.IO.File]::Create($Dest)
    try { $proc.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose() }
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
        throw "git couldn't read $RelPath from the engine repo: $($errTask.Result)"
    }
}

function Get-FilesFast([string]$Root, [string]$Pattern) {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Root)) { return }
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Root, $Pattern, [System.IO.SearchOption]::AllDirectories)) { $list.Add($f) }
    } catch {
        $list.Clear()
        foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -Filter $Pattern -File -ErrorAction SilentlyContinue)) { $list.Add($f.FullName) }
    }
    return $list.ToArray()
}

# .Build.cs files under a folder, whatever the case of the extension (some of Epic's are named .build.cs).
function Get-BuildCsFiles([string]$Root) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-FilesFast $Root '*.cs')) { if ($f -and $f.EndsWith('.Build.cs', [System.StringComparison]::OrdinalIgnoreCase)) { $list.Add($f) } }
    return ,$list.ToArray()
}

# Copies a folder tree. Never overwrites existing files when -NoOverwrite is set. -Files limits the copy to file
# patterns such as *.uasset.
function Copy-Tree([string]$From, [string]$To, [string[]]$ExcludeDirs = @(), [switch]$NoOverwrite, [string[]]$Files = @()) {
    if (-not (Test-Path -LiteralPath $To)) { New-Item -ItemType Directory -Path $To -Force | Out-Null }
    if ($OnWindows) {
        $a = @($From, $To) + @($Files) + @('/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        if ($NoOverwrite) { $a += @('/XC', '/XN', '/XO') }
        if ($ExcludeDirs.Count -gt 0) { $a += '/XD'; $a += $ExcludeDirs }
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & robocopy @a | Out-Null } finally { $ErrorActionPreference = $old }
        if ($LASTEXITCODE -ge 8) { throw "Copy failed (robocopy code $LASTEXITCODE): $From -> $To" }
        return
    }
    $fromFull = (Resolve-Path -LiteralPath $From).Path.TrimEnd($Sep)
    foreach ($f in (Get-FilesFast $fromFull '*')) {
        $skip = $false
        foreach ($x in $ExcludeDirs) { if ($f.StartsWith($x.TrimEnd($Sep) + $Sep)) { $skip = $true; break } }
        if ($Files.Count -gt 0) {
            $leaf = [System.IO.Path]::GetFileName($f)
            if (-not @($Files | Where-Object { $leaf -like $_ })) { $skip = $true }
        }
        if ($skip) { continue }
        $dest = $To.TrimEnd($Sep) + $f.Substring($fromFull.Length)
        if ($NoOverwrite -and (Test-Path -LiteralPath $dest)) { continue }
        $dd = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
        Copy-Item -LiteralPath $f -Destination $dest -Force
    }
}

function Backup-Item([string]$Path, [string]$ProjectRoot) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not $S.BackupRoot) { $S.BackupRoot = P $ProjectRoot '_NativeVR_Backup' $Stamp }
    $rel = $Path.Substring($ProjectRoot.TrimEnd($Sep).Length).TrimStart($Sep)
    $dest = P $S.BackupRoot $rel
    $dd = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
    Move-Item -LiteralPath $Path -Destination $dest -Force
    Note "Moved old $rel to the backup folder"
}

function Get-SemVer([string]$v) {
    if ($v -match '^\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?') {
        $b = 0; $c = 0
        if ($Matches[2]) { $b = $Matches[2] }
        if ($Matches[3]) { $c = $Matches[3] }
        return ('{0}.{1}.{2}' -f $Matches[1], $b, $c)
    }
    return '1.0.0'
}

$EditorModuleTypes = @('Editor', 'EditorNoCommandlet', 'EditorAndProgram', 'UncookedOnly', 'Developer', 'DeveloperTool', 'Program')
function Test-EditorOnlyPlugin($Desc) {
    $mods = As-Array (Get-Prop $Desc 'Modules')
    if ($mods.Count -eq 0) { return $false }
    foreach ($m in $mods) { if ($EditorModuleTypes -notcontains [string](Get-Prop $m 'Type')) { return $false } }
    return $true
}
function Test-AllowsWin64($Entry) {
    $allow = As-Array (Get-Prop $Entry 'PlatformAllowList')
    if ($allow.Count -eq 0) { $allow = As-Array (Get-Prop $Entry 'WhitelistPlatforms') }
    if ($allow.Count -gt 0 -and $allow -notcontains 'Win64') { return $false }
    $deny = As-Array (Get-Prop $Entry 'PlatformDenyList')
    if ($deny -contains 'Win64') { return $false }
    $stp = As-Array (Get-Prop $Entry 'SupportedTargetPlatforms')
    if ($stp.Count -gt 0 -and $stp -notcontains 'Win64') { return $false }
    return $true
}

# Reads which modules a Build.cs file links against and which it only needs headers from. Modules it adds only for
# other platforms, e.g. inside  if (Target.Platform == UnrealTargetPlatform.Android) { ... }, are listed apart in
# OtherPlatform: the Windows editor doesn't need them.
function Get-BuildCsDeps([string]$Path) {
    $t = [System.IO.File]::ReadAllText($Path)
    $t = [regex]::Replace($t, '/\*.*?\*/', '', 'Singleline')
    $t = [regex]::Replace($t, '//[^\r\n]*', '')
    $link = New-Set; $incl = New-Set; $other = New-Set
    $calls = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($t, '(Public|Private)(Dependency|IncludePath)ModuleNames\s*\.\s*(AddRange|Add)\s*\((.*?)\)\s*;', 'Singleline')) {
        $calls.Add([pscustomobject]@{ Pos = $m.Index; Names = $m.Groups[4].Value; Link = ($m.Groups[2].Value -eq 'Dependency') })
    }
    foreach ($m in [regex]::Matches($t, 'AddEngineThirdParty(Private|Public)(Static|Dynamic)Dependencies\s*\(\s*Target\s*,(.*?)\)\s*;', 'Singleline')) {
        $calls.Add([pscustomobject]@{ Pos = $m.Index; Names = $m.Groups[3].Value; Link = $true })
    }
    # One pass over the file keeps the text in front of each open brace (the "if (...)" a block belongs to), so each
    # call can be checked against every block around it, plus an "if (...)" on its own line without braces.
    $sorted = @($calls | Sort-Object Pos)
    $heads = New-Object System.Collections.Generic.List[string]
    $last = 0; $i = 0
    foreach ($c in $sorted) {
        $pos = [int]$c.Pos
        for (; $i -lt $pos; $i++) {
            $ch = $t[$i]
            if ($ch -eq '{') { $heads.Add($t.Substring($last, $i - $last)); $last = $i + 1 }
            elseif ($ch -eq '}') { if ($heads.Count -gt 0) { $heads.RemoveAt($heads.Count - 1) }; $last = $i + 1 }
            elseif ($ch -eq ';') { $last = $i + 1 }
        }
        $elsewhere = $false
        foreach ($h in (@($heads) + @($t.Substring($last, $pos - $last)))) {
            if ($h -match '\bif\s*\(' -and $h -match 'Platform' -and $h -notmatch 'Win64|Windows|Microsoft|Desktop|!=') { $elsewhere = $true; break }
        }
        foreach ($q in [regex]::Matches($c.Names, '"([A-Za-z_][A-Za-z0-9_]*)"')) {
            $n = $q.Groups[1].Value
            if ($elsewhere) { [void]$other.Add($n) }
            elseif ($c.Link) { [void]$link.Add($n) }
            else { [void]$incl.Add($n) }
        }
    }
    foreach ($n in @($other)) { if ($link.Contains($n) -or $incl.Contains($n)) { [void]$other.Remove($n) } }
    return @{ Link = $link; Include = $incl; OtherPlatform = $other }
}

# Indexes plugins (.uplugin) and modules (.Build.cs) under a root, from a list of relative paths.
# Returns @{ Plugins = name -> rel dir; PluginFile = name -> rel .uplugin; Modules = name -> @{ Dir; BuildCs; Plugin } }
function New-TreeIndex([string[]]$RelPaths) {
    $idx = @{ Plugins = @{}; PluginFile = @{}; Modules = @{} }
    $pluginDirs = @{}
    foreach ($r in $RelPaths) {
        if ($r.EndsWith('.uplugin')) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($r)
            $dir = $r.Substring(0, [Math]::Max(0, $r.LastIndexOf('/')))
            if (-not $idx.Plugins.ContainsKey($name)) { $idx.Plugins[$name] = $dir; $idx.PluginFile[$name] = $r }
            $pluginDirs[$dir] = $name
        }
    }
    foreach ($r in $RelPaths) {
        if (-not $r.EndsWith('.Build.cs', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $file = $r.Substring($r.LastIndexOf('/') + 1)
        $name = $file.Substring(0, $file.Length - '.Build.cs'.Length)
        if ($idx.Modules.ContainsKey($name)) { continue }
        $dir = $r.Substring(0, [Math]::Max(0, $r.LastIndexOf('/')))
        $owner = $null; $d = $dir
        while ($d.Length -gt 0) {
            if ($pluginDirs.ContainsKey($d)) { $owner = $pluginDirs[$d]; break }
            $cut = $d.LastIndexOf('/')
            if ($cut -lt 0) { break }
            $d = $d.Substring(0, $cut)
        }
        $idx.Modules[$name] = @{ Dir = $dir; BuildCs = $r; Plugin = $owner }
    }
    return $idx
}

# Finds .uplugin and .Build.cs files. Walks folder by folder, skipping folders that never hold them
# (much faster on a full engine install) and stepping past any folder Windows can't read (very long paths).
$IndexSkipDirs = @('Binaries', 'Intermediate', 'Content', 'Saved', 'Resources', 'Shaders', 'DerivedDataCache', 'Config', 'Docs', 'Documentation', '.git')
function Get-RelPaths([string]$Root, [string[]]$SubDirs, [string[]]$Suffixes) {
    $rootFull = $Root.TrimEnd($Sep)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($s in $SubDirs) {
        $start = P $rootFull (To-Native $s)
        if (-not (Test-Path -LiteralPath $start)) { continue }
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($start)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            $files = @(); $subs = @()
            try { $files = [System.IO.Directory]::GetFiles($dir) } catch { }
            foreach ($f in $files) {
                foreach ($suf in $Suffixes) {
                    if ($f.EndsWith($suf, [System.StringComparison]::OrdinalIgnoreCase)) { $list.Add($f.Substring($rootFull.Length + 1).Replace('\', '/')); break }
                }
            }
            try { $subs = [System.IO.Directory]::GetDirectories($dir) } catch { }
            foreach ($d in $subs) { if ($IndexSkipDirs -notcontains [System.IO.Path]::GetFileName($d)) { $stack.Push($d) } }
        }
    }
    return $list.ToArray()
}

# Scans the start of every asset for references to C++ modules (/Script/Name) and plugin content (/Name/...).
function Get-AssetReferences([string]$ContentDir) {
    $mods = New-Set; $mounts = New-Set
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $count = 0
    foreach ($f in (Get-FilesFast $ContentDir '*')) {
        if ($f -notmatch '\.(uasset|umap)$') { continue }
        $count++
        $fs = [System.IO.File]::OpenRead($f)
        try {
            $len = [int][Math]::Min($fs.Length, 2MB)
            $buf = New-Object byte[] $len
            $got = 0
            while ($got -lt $len) { $n = $fs.Read($buf, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
        } finally { $fs.Dispose() }
        $s = $latin1.GetString($buf, 0, $got)
        foreach ($m in [regex]::Matches($s, '/Script/([A-Za-z_][A-Za-z0-9_]*)')) { [void]$mods.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($s, '\x00/([A-Za-z_][A-Za-z0-9_]*)/[A-Za-z0-9_]')) { [void]$mounts.Add($m.Groups[1].Value) }
    }
    return @{ Modules = $mods; Mounts = $mounts; AssetCount = $count }
}

# The shared content packs a template lists in Config\TemplateDefs.ini, e.g.
#   SharedContentPacks=(MountName="LevelPrototyping",DetailLevels=("High"))
# Epic's project wizard copies Templates\TemplateResources\<level>\<mount>\Content into the new project's
# Content\<mount> folder. Returns each pack's mount name and its detail levels, best first.
function Read-SharedPackDefs([string]$TemplateDir) {
    $list = New-Object System.Collections.Generic.List[object]
    $ini = P $TemplateDir 'Config' 'TemplateDefs.ini'
    if (-not (Test-Path -LiteralPath $ini)) { return ,$list.ToArray() }
    foreach ($line in [System.IO.File]::ReadAllLines($ini)) {
        if ($line -notmatch '^\s*\+?SharedContentPacks\s*=\s*\((.*)\)\s*$') { continue }
        $body = $Matches[1]
        if ($body -notmatch 'MountName\s*=\s*"([^"]+)"') { continue }
        $mount = $Matches[1]
        $levels = New-Object System.Collections.Generic.List[string]
        if ($body -match 'DetailLevels\s*=\s*\(([^)]*)\)') { foreach ($q in [regex]::Matches($Matches[1], '"([^"]+)"')) { $levels.Add($q.Groups[1].Value) } }
        if ($levels.Count -eq 0) { $levels.Add('Standard') }
        # The wizard prefers the High version of a pack when the template allows it.
        $ordered = @($levels | Sort-Object { if ($_ -eq 'High') { 0 } elseif ($_ -eq 'Standard') { 1 } else { 2 } })
        $list.Add([pscustomobject]@{ Mount = $mount; Levels = $ordered })
    }
    return ,$list.ToArray()
}

# The part of an InputMappingContext path after its mount, e.g. VRTemplate/Input/IMC_Default.IMC_Default (lower case).
function Get-ImcKey([string]$Line) {
    if ($Line -match 'InputMappingContext\s*=\s*"/[^/"]+/([^"]+)"') { return $Matches[1].ToLowerInvariant() }
    return $null
}

# OpenXR only binds controller buttons for the input mapping contexts it knows when the XR session starts. The VR
# Template lists its contexts in Enhanced Input's Default Mapping Contexts (its own DefaultInput.ini); FactoryGame's
# input config has none, so without this the template's buttons do nothing in VR Preview. Adds the template's lines
# to the project's Config\DefaultInput.ini (or fixes their paths if the content moved). Returns a note, or $null.
function Update-InputContexts([string]$TemplateIni, [string]$ProjectIni) {
    $section = '[/Script/EnhancedInput.EnhancedInputDeveloperSettings]'
    $want = New-Object System.Collections.Generic.List[string]
    $inSec = $false
    foreach ($l in [System.IO.File]::ReadAllLines($TemplateIni)) {
        $t = $l.Trim()
        if ($t.StartsWith('[')) { $inSec = ($t -ieq $section); continue }
        if ($inSec -and $t -match '^\+DefaultMappingContexts\s*=' -and (Get-ImcKey $t)) { $want.Add($t) }
    }
    if ($want.Count -eq 0) { return $null }
    # Point each line at wherever that content is now: the project's Content (/Game) or the mod, if it was moved there.
    for ($i = 0; $i -lt $want.Count; $i++) {
        if ($want[$i] -match 'InputMappingContext\s*=\s*"/Game/([^/"]+)/') {
            $top = $Matches[1]
            if (-not (Test-Path -LiteralPath (P $ProjectDir 'Content' $top)) -and (Test-Path -LiteralPath (P $ModDir 'Content' $top))) {
                $want[$i] = $want[$i].Replace('"/Game/' + $top + '/', '"/' + $ModName + '/' + $top + '/')
            }
        }
    }
    $bytes = [System.IO.File]::ReadAllBytes($ProjectIni)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $start = 0; if ($bom) { $start = 3 }
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes, $start, $bytes.Length - $start)
    $nl = "`n"; if ($text.Contains("`r`n")) { $nl = "`r`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($text -split "`r?`n")) { $lines.Add($l) }
    $secStart = -1; $secEnd = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($secStart -lt 0) { if ($t -ieq $section) { $secStart = $i } }
        elseif ($t.StartsWith('[')) { $secEnd = $i; break }
    }
    $wantByKey = [ordered]@{}
    foreach ($w in $want) { $wantByKey[(Get-ImcKey $w)] = $w }
    $added = 0; $fixed = 0
    if ($secStart -lt 0) {
        while ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -eq '') { $lines.RemoveAt($lines.Count - 1) }
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add($section)
        foreach ($w in $wantByKey.Values) { $lines.Add($w); $added++ }
        $lines.Add('')
    } else {
        $done = New-Set
        $last = $secStart
        for ($i = $secStart + 1; $i -lt $secEnd; $i++) {
            $t = $lines[$i].Trim()
            if ($t -ne '') { $last = $i }
            if ($t -notmatch '^\+DefaultMappingContexts\s*=') { continue }
            $k = Get-ImcKey $t
            if (-not $k -or -not $wantByKey.Contains($k)) { continue }
            [void]$done.Add($k)
            if ($t -ne $wantByKey[$k]) { $lines[$i] = $wantByKey[$k]; $fixed++ }
        }
        $at = $last + 1
        foreach ($k in @($wantByKey.Keys)) {
            if ($done.Contains($k)) { continue }
            $lines.Insert($at, $wantByKey[$k]); $at++; $added++
        }
    }
    if ($added -eq 0 -and $fixed -eq 0) { return 'Config\DefaultInput.ini already lists the template''s input mapping contexts' }
    Copy-Item -LiteralPath $ProjectIni -Destination (P $LogDir "DefaultInput.ini.before-$Stamp") -Force
    $out = New-Object System.Collections.Generic.List[byte]
    if ($bom) { $out.AddRange([byte[]](0xEF, 0xBB, 0xBF)) }
    $out.AddRange((New-Object System.Text.UTF8Encoding($false)).GetBytes(($lines -join $nl)))
    [System.IO.File]::WriteAllBytes($ProjectIni, $out.ToArray())
    $what = @()
    if ($added -gt 0) { $what += "added $added" }
    if ($fixed -gt 0) { $what += "updated the path of $fixed" }
    return ("Config\DefaultInput.ini: {0} of the template's input mapping contexts (OpenXR needs them for the controller buttons; old copy kept in Saved\NativeVR-Setup)" -f ($what -join ' and '))
}

# After a fresh copy of one of Epic's plugins (first run or -Fresh), brings back modules that had been added to the old
# copy for NativeVR (for example a third-party or engine module the CSS install lacks), so starting over doesn't undo them.
function Restore-AddedModules([string]$OldDir, [string]$NewDir, $Desc, [string]$PluginName) {
    if (-not $OldDir -or -not (Test-Path -LiteralPath $OldDir)) { return }
    $have = New-Set
    foreach ($bc in (Get-BuildCsFiles $NewDir)) { [void]$have.Add((([System.IO.Path]::GetFileName($bc)) -replace '\.Build\.cs$', '')) }
    $restored = New-Set
    $oldFull = $OldDir.TrimEnd($Sep)
    foreach ($bc in (Get-BuildCsFiles $OldDir)) {
        $mod = ([System.IO.Path]::GetFileName($bc)) -replace '\.Build\.cs$', ''
        if ($have.Contains($mod)) { continue }
        $modDir = Split-Path -Parent $bc
        $rel = $modDir.Substring($oldFull.Length).TrimStart($Sep)
        if ($rel -match '(^|[\\/])(Intermediate|Binaries|Saved)([\\/]|$)') { continue }
        Copy-Tree $modDir (P $NewDir $rel) -ExcludeDirs @((P $modDir 'Intermediate'), (P $modDir 'Binaries'))
        [void]$have.Add($mod)
        [void]$restored.Add($mod)
    }
    if ($restored.Count -eq 0) { return }
    $oldFile = P $OldDir "$PluginName.uplugin"
    if (Test-Path -LiteralPath $oldFile) {
        $mods = New-Object System.Collections.Generic.List[object]
        $names = New-Set
        foreach ($m in (As-Array (Get-Prop $Desc 'Modules'))) { $mods.Add($m); [void]$names.Add([string](Get-Prop $m 'Name')) }
        foreach ($m in (As-Array (Get-Prop (Read-Json $oldFile) 'Modules'))) {
            $mn = [string](Get-Prop $m 'Name')
            if ($restored.Contains($mn) -and $names.Add($mn)) { $mods.Add($m) }
        }
        Set-Prop $Desc 'Modules' ([object[]]$mods.ToArray())
    }
    Ok ("{0}: kept what was added to it for NativeVR: {1}" -f $PluginName, (@($restored) -join ', '))
}

# True when a file contains the given text (an asset file lists the names it uses as plain text).
function Test-FileHasText([string]$Path, [string]$Text) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    return $latin1.GetString([System.IO.File]::ReadAllBytes($Path)).Contains($Text)
}

# FactoryGame turns baked lighting off (r.AllowStaticLighting=False in its DefaultEngine.ini). A light set to Static
# exists only in the map's baked lightmaps, which FactoryGame ignores, so it never shows. Epic's template map bakes its
# campfire light (PointLight4), a fill light (PointLight5) and the sky light that way. This switches those three to
# Movable, the same as picking Movable in the Details panel and saving. The map stores each light's Mobility as a name,
# so the change is one byte per light: name 200 in the map's name list (EComponentMobility::Static) becomes name 199
# (EComponentMobility::Movable). Only Epic's exact file is changed (checked by its SHA1, the hash the engine's download
# list gives for it); the untouched original stays in the download cache.
# Returns 'done', 'already', or 'changed' (the map isn't Epic's original, so it was left alone).
function Repair-TemplateMapLights([string]$Path) {
    $original = 'CA9BE0D6600EF8545042556769A7FA42BD8FF6AF'
    $fixed = '1F7B37F54D71BB6E9B4771AD463F17EB1BC30D52'
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    $sha.Dispose()
    if ($hash -eq $fixed) { return 'already' }
    if ($hash -ne $original) { return 'changed' }
    foreach ($o in @(118808, 119265, 131124)) {
        if ($bytes[$o] -ne 200) { return 'changed' }
        $bytes[$o] = 199
    }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    return 'done'
}

# The OpenXR SDK's build rules from the engine source, pointed at a copy inside the OpenXR mod: the headers and loader
# sit next to the rules, and the build copies the loader into the mod's own Binaries folder (NativeVRCore hands it to
# OpenXR from there). Every setting stays Epic's; only paths change. Returns $null when a line it changes isn't there
# (the file isn't the one this was written for), so nothing half-changed gets written.
function Convert-OpenXRSdkBuildCs([string]$Text, [string]$From) {
    $nl = "`n"; if ($Text.Contains("`r`n")) { $nl = "`r`n" }
    $pairs = @(
        @('protected string RootPath { get => Target.UEThirdPartySourceDirectory + "OpenXR"; }', 'protected string RootPath { get => ModuleDirectory; }'),
        @('RuntimeDependencies.Add(Path.Combine("$(EngineDir)/Binaries/ThirdParty/OpenXR", PlatformDir, "openxr_loader.dll"));', 'RuntimeDependencies.Add("$(PluginDir)/Binaries/Win64/openxr_loader.dll", Path.Combine(LoaderPath, PlatformDir, "openxr_loader.dll"));'),
        @('string OpenXRPath = "$(EngineDir)/Binaries/ThirdParty/OpenXR/linux/x86_64-unknown-linux-gnu/libopenxr_loader.so";', 'string OpenXRPath = Path.Combine(LoaderPath, "linux/x86_64-unknown-linux-gnu/libopenxr_loader.so");'),
        @("PublicAdditionalLibraries.Add(OpenXRPath);$nl`t`t`tRuntimeDependencies.Add(OpenXRPath);$nl`t`t}", "PublicAdditionalLibraries.Add(OpenXRPath);$nl`t`t`tRuntimeDependencies.Add(""`$(PluginDir)/Binaries/Linux/libopenxr_loader.so"", OpenXRPath);$nl`t`t}"),
        @('string BasePath = "$(EngineDir)/Binaries/ThirdParty/OpenXR/Android/";', 'string BasePath = Path.Combine(LoaderPath, "Android");'),
        @('AdditionalPropertiesForReceipt.Add("AndroidPlugin", "Source/ThirdParty/OpenXR/OpenXR_APL.xml");', 'AdditionalPropertiesForReceipt.Add("AndroidPlugin", Path.Combine(RootPath, "OpenXR_APL.xml"));')
    )
    foreach ($pair in $pairs) {
        $at = $Text.IndexOf($pair[0])
        if ($at -lt 0) { return $null }
        $Text = $Text.Substring(0, $at) + $pair[1] + $Text.Substring($at + $pair[0].Length)
    }
    $first = $Text.IndexOf($nl)
    if ($first -lt 0) { return $null }
    $note = @(
        '',
        "// NativeVR: vendored from the engine source (Engine/Source/ThirdParty/OpenXR, $From)",
        '// because the CSS engine install does not ship this module. Same settings as Epic''s file; the only change is',
        '// that every path points inside this mod instead of the engine folder. The build copies openxr_loader.dll',
        '// into this mod''s Binaries\Win64 folder. OpenXRHMD itself only looks for the loader in the engine folder,',
        '// so the NativeVRCore mod loads this copy and hands it to OpenXR (IOpenXRExtensionPlugin::GetCustomLoader).'
    ) -join $nl
    return $Text.Substring(0, $first) + $nl + $note + $Text.Substring($first)
}

# Fixes only the editor can make, as a Python script for Unreal's Python plugin. The setup runs it once without a
# window; it can also be run by hand in the editor. Every step checks first, so it is safe to run more than once.
$EditorFixesPy = @'
# NativeVR: fixes only the Unreal editor can make. Written by Setup-NativeVR.ps1; safe to run more than once.
# The setup script runs it without a window (UnrealEditor-Cmd -run=pythonscript). To run it by hand in the editor:
# Window > Output Log, set the box at the bottom left to Cmd, and enter:  py "<full path of this file>"
import json
import os
import unreal

MOD = '{{MODNAME}}'
DATA_ASSET_FILE = '{{DATAASSETFILE}}'
GRID_MATERIAL = '{{GRIDMATERIAL}}'
RESULT_FILE = '{{RESULTFILE}}'
results = {}


def note(key, value):
    results[key] = value
    unreal.log('NativeVR fixes: %s: %s' % (key, value))


def save(path):
    return unreal.EditorAssetLibrary.save_asset(path, only_if_is_dirty=False)


# The template's floor and wall material is used on Nanite meshes (the LevelPrototyping cubes), but Epic saved it
# without "Used with Nanite". The editor then adds the flag in memory at every start and warns about it in Map Check.
try:
    material = unreal.load_asset(GRID_MATERIAL) if GRID_MATERIAL else None
    if material is None:
        note('nanite', 'material not found' if GRID_MATERIAL else 'skipped')
    elif material.get_editor_property('used_with_nanite'):
        note('nanite', 'already')
    else:
        try:
            material.set_editor_property('used_with_nanite', True)
        except Exception:
            unreal.MaterialEditingLibrary.set_material_usage(material, unreal.MaterialUsage.MATUSAGE_NANITE)
        if material.get_editor_property('used_with_nanite'):
            note('nanite', 'done' if save(GRID_MATERIAL) else 'could not save')
        else:
            note('nanite', 'the flag did not stick')
except Exception as error:
    note('nanite', 'error: %s' % error)

# Every 1.2 content mod needs an FGGameFeatureData data asset named after the mod in its content root.
try:
    path = '/%s/%s' % (MOD, MOD)
    if os.path.exists(DATA_ASSET_FILE) or unreal.EditorAssetLibrary.does_asset_exist(path):
        note('data_asset', 'already')
    else:
        data_class = unreal.load_class(None, '/Script/FactoryGame.FGGameFeatureData')
        factory = unreal.DataAssetFactory()
        factory.set_editor_property('data_asset_class', data_class)
        asset = unreal.AssetToolsHelpers.get_asset_tools().create_asset(MOD, '/' + MOD, data_class, factory)
        if asset is None:
            note('data_asset', 'could not create')
        else:
            note('data_asset', 'done' if save(path) else 'could not save')
except Exception as error:
    note('data_asset', 'error: %s' % error)

if RESULT_FILE:
    with open(RESULT_FILE, 'w') as handle:
        json.dump(results, handle)
'@

# Runs the editor once without a window (UnrealEditor-Cmd -run=pythonscript) on the fixes script. Returns the script's
# results (step -> outcome), or a sentence saying why it didn't run.
function Invoke-EditorFixes([string]$PyFile, [string]$ResultFile, [string]$LogFile) {
    $exe = P $EngineDir 'Engine' 'Binaries' 'Win64' 'UnrealEditor-Cmd.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return "UnrealEditor-Cmd.exe isn't in $(Split-Path -Parent $exe)" }
    Remove-Item -LiteralPath $ResultFile -Force -ErrorAction SilentlyContinue
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ('"{0}" -run=pythonscript -script="{1}" -unattended -nosplash -nop4 -nosound -abslog="{2}"' -f $Uproject, $PyFile, $LogFile)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # The editor's console output is thrown away (the full log goes to $LogFile); reading it keeps the editor from stalling.
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return "the editor couldn't be started: $($_.Exception.Message)" }
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $minutes = 10
    if (-not $proc.WaitForExit($minutes * 60000)) {
        try { $proc.Kill() } catch { }
        return "the editor didn't finish within $minutes minutes (log: $LogFile)"
    }
    $proc.WaitForExit()
    $code = $proc.ExitCode
    $proc.Dispose()
    if (-not (Test-Path -LiteralPath $ResultFile)) { return "the editor stopped (exit code $code) before the fixes ran (log: $LogFile)" }
    $res = [ordered]@{}
    try { foreach ($pp in (Read-Json $ResultFile).PSObject.Properties) { $res[$pp.Name] = [string]$pp.Value } }
    catch { return "the fixes' result file couldn't be read ($ResultFile)" }
    return $res
}

# ----------------------------------------------------- binary dependency fetch ---
# Unreal keeps art, maps and prebuilt libraries out of git. Its Setup.bat reads
# Engine\Build\*.gitdeps.xml, which lists every such file, the compressed "pack"
# on Epic's server that holds it, and where inside the pack it sits. This does
# the same thing, but only for the folders we ask for.

function Test-Prefix([string]$Name, [string[]]$Prefixes) {
    foreach ($p in $Prefixes) { if ($Name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

function Read-GitDeps([string[]]$ManifestPaths, [string[]]$KeepPrefixes) {
    $files = @{}; $blobs = @{}; $packs = @{}
    foreach ($path in $ManifestPaths) {
        $set = New-Object System.Xml.XmlReaderSettings
        $set.IgnoreWhitespace = $true
        $set.IgnoreComments = $true
        $set.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
        $base = 'http://cdn.unrealengine.com/dependencies'
        $r = [System.Xml.XmlReader]::Create($path, $set)
        try {
            while ($r.Read()) {
                if ($r.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                switch ($r.LocalName) {
                    'DependencyManifest' { $b = $r.GetAttribute('BaseUrl'); if ($b) { $base = $b } }
                    'File' {
                        $n = $r.GetAttribute('Name')
                        if ($n -and (Test-Prefix $n $KeepPrefixes)) { $files[$n] = $r.GetAttribute('Hash') }
                    }
                    'Blob' { $blobs[$r.GetAttribute('Hash')] = @([long]$r.GetAttribute('Size'), $r.GetAttribute('PackHash'), [long]$r.GetAttribute('PackOffset')) }
                    'Pack' { $packs[$r.GetAttribute('Hash')] = @($base, $r.GetAttribute('RemotePath'), [long]('0' + $r.GetAttribute('CompressedSize'))) }
                }
            }
        } finally { $r.Close() }
    }
    return @{ Files = $files; Blobs = $blobs; Packs = $packs }
}

function Read-Exact($Stream, [byte[]]$Buffer, [int]$Count) {
    $got = 0
    while ($got -lt $Count) {
        $n = $Stream.Read($Buffer, $got, $Count - $got)
        if ($n -le 0) { throw 'Unexpected end of a downloaded pack.' }
        $got += $n
    }
}

function Invoke-GitDepsFetch($Deps, [string]$Root, [string[]]$Prefixes, [string]$TempDir) {
    # The engine's .gitignore ignores these downloaded files, and whenever the list of downloaded folders changes, git
    # deletes folders outside that list holding only ignored files. So each folder joins the list before downloading.
    if (Test-Path -LiteralPath (P $Root '.git' 'info' 'sparse-checkout')) {
        $dirs = @($Prefixes | ForEach-Object { $_.TrimEnd('/') } | Where-Object { $_ } | Select-Object -Unique)
        if ($dirs.Count -gt 0) { Invoke-GitLive (@('-C', $Root, 'sparse-checkout', 'add') + $dirs) }
    }
    $want = @{}
    $needed = 0
    foreach ($kv in $Deps.Files.GetEnumerator()) {
        if (-not (Test-Prefix $kv.Key $Prefixes)) { continue }
        $blob = $Deps.Blobs[$kv.Value]
        if (-not $blob) { Warn "No download entry for $($kv.Key)"; continue }
        $dest = P $Root (To-Native $kv.Key)
        if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -eq $blob[0])) { continue }
        if (-not $want.ContainsKey($kv.Value)) { $want[$kv.Value] = New-Object System.Collections.Generic.List[string] }
        $want[$kv.Value].Add($dest)
        $needed++
    }
    if ($needed -eq 0) { Ok 'Nothing new to download for these folders'; return 0 }

    $byPack = @{}
    foreach ($h in $want.Keys) {
        $b = $Deps.Blobs[$h]
        if (-not $byPack.ContainsKey($b[1])) { $byPack[$b[1]] = New-Object System.Collections.Generic.List[object] }
        $byPack[$b[1]].Add([pscustomobject]@{ Offset = $b[2]; Size = $b[0]; Hash = $h })
    }
    $total = 0L
    foreach ($pk in $byPack.Keys) { if ($Deps.Packs[$pk]) { $total += $Deps.Packs[$pk][2] } }
    Note ("{0} files from {1} download pack(s), about {2:N1} MB" -f $needed, $byPack.Count, ($total / 1MB))

    if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
    $client = New-Object System.Net.WebClient
    $client.Headers['User-Agent'] = 'NativeVR-Setup'
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $buf = New-Object byte[] 1048576
    $bad = 0; $i = 0
    foreach ($pk in @($byPack.Keys)) {
        $i++
        $info = $Deps.Packs[$pk]
        if (-not $info) { Warn "Pack $pk is missing from the manifest"; continue }
        $url = '{0}/{1}/{2}' -f $info[0].TrimEnd('/'), $info[1], $pk
        $tmp = P $TempDir $pk
        $tries = 0
        while ($true) {
            try { $client.DownloadFile($url, $tmp); break }
            catch {
                $tries++
                if ($tries -ge 3) { throw "Download failed after 3 tries: $url`n$($_.Exception.Message)" }
                Start-Sleep -Seconds (2 * $tries)
            }
        }
        if (($i % 10) -eq 0 -or $i -eq $byPack.Count) { Note ("pack {0}/{1}" -f $i, $byPack.Count) }
        $entries = @($byPack[$pk] | Sort-Object Offset)
        $fs = [System.IO.File]::OpenRead($tmp)
        $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $pos = 0L
            foreach ($e in $entries) {
                $skip = $e.Offset - $pos
                while ($skip -gt 0) {
                    $n = [int][Math]::Min([long]$buf.Length, $skip)
                    Read-Exact $gz $buf $n
                    $skip -= $n
                }
                $targets = $want[$e.Hash]
                $first = $targets[0]
                $dd = Split-Path -Parent $first
                if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                $out = [System.IO.File]::Create($first)
                [void]$sha.Initialize()
                try {
                    $left = [long]$e.Size
                    while ($left -gt 0) {
                        $n = [int][Math]::Min([long]$buf.Length, $left)
                        Read-Exact $gz $buf $n
                        $out.Write($buf, 0, $n)
                        [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
                        $left -= $n
                    }
                    [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                } finally { $out.Dispose() }
                $hex = [System.BitConverter]::ToString($sha.Hash).Replace('-', '')
                if ($hex -ne $e.Hash.ToUpperInvariant()) { $bad++ }
                for ($t = 1; $t -lt $targets.Count; $t++) {
                    $td = Split-Path -Parent $targets[$t]
                    if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Path $td -Force | Out-Null }
                    Copy-Item -LiteralPath $first -Destination $targets[$t] -Force
                }
                $pos = $e.Offset + $e.Size
            }
        } finally { $gz.Dispose(); $fs.Dispose() }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    $client.Dispose()
    if ($bad -gt 0) { Warn "$bad downloaded files didn't match their checksum. Re-run the script; if it repeats, tell Claude." }
    Ok "Downloaded $needed files"
    return $needed
}

# ================================================================= main ===

$LogDir = $null
try {
    # ---------------------------------------------------------- project ---
    $ProjectFoundBy = ''
    if ($ProjectDir) {
        $given = $ProjectDir
        $ProjectDir = Find-ProjectRoot $given
        if (-not $ProjectDir) { throw "FactoryGame.uproject wasn't found in $given or any folder above it." }
    } else {
        $ProjectDir = Find-ProjectRoot (Get-Location).Path
        if (-not $ProjectDir -and $PSScriptRoot) { $ProjectDir = Find-ProjectRoot $PSScriptRoot }
        if (-not $ProjectDir) { $ProjectDir = Find-ProjectByScan; if ($ProjectDir) { $ProjectFoundBy = ' (found by searching your drives)' } }
        if (-not $ProjectDir) { throw "Couldn't find your starter project (the folder with FactoryGame.uproject). Run again with -ProjectDir 'C:\path\to\project'." }
    }
    $Uproject = P $ProjectDir 'FactoryGame.uproject'
    $LogDir = P $ProjectDir 'Saved' 'NativeVR-Setup'
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    try { Start-Transcript -Path (P $LogDir "setup-$Stamp.log") -Force | Out-Null } catch { }
    try { if ($RunningAsFile) { Copy-Item -LiteralPath $PSCommandPath -Destination (P $LogDir 'Setup-NativeVR.ps1') -Force } } catch { }

    Step 'Checking your setup'
    Ok "Project: $ProjectDir$ProjectFoundBy"
    if ($OnWindows) {
        $running = @(Get-Process -Name 'UnrealEditor', 'UnrealEditor-Cmd' -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) { throw 'The Unreal editor is open. Close it (and let it finish closing), then run this again.' }
    }

    # ----------------------------------------------------------- engine ---
    $uprojectJson = Read-Json $Uproject
    $assoc = [string](Get-Prop $uprojectJson 'EngineAssociation')
    if (-not $EngineDir -and $OnWindows -and $assoc) {
        try { $v = (Get-ItemProperty -Path 'HKCU:\Software\Epic Games\Unreal Engine\Builds' -ErrorAction Stop).$assoc; if ($v) { $EngineDir = $v } } catch { }
        if (-not $EngineDir) {
            try { $v = (Get-ItemProperty -Path "HKLM:\SOFTWARE\EpicGames\Unreal Engine\$assoc" -ErrorAction Stop).InstalledDirectory; if ($v) { $EngineDir = $v } } catch { }
        }
    }
    if (-not $EngineDir -and $OnWindows) { $EngineDir = 'C:\Program Files\Unreal Engine - CSS' }
    if (-not $EngineDir) { throw 'Pass -EngineDir with your CSS engine install folder.' }
    $EngineDir = [System.IO.Path]::GetFullPath($EngineDir.Trim()).TrimEnd('\', '/')
    $BuildBat = P $EngineDir 'Engine' 'Build' 'BatchFiles' 'Build.bat'
    if (-not (Test-Path -LiteralPath (P $EngineDir 'Engine'))) { throw "No engine found at $EngineDir. Pass -EngineDir with the folder that contains 'Engine'." }
    Ok "Engine ($assoc): $EngineDir"
    $engineFull = [System.IO.Path]::GetFullPath($EngineDir).TrimEnd($Sep) + $Sep
    foreach ($p in @($ProjectDir, $CacheDir)) {
        if (([System.IO.Path]::GetFullPath($p).TrimEnd($Sep) + $Sep).StartsWith($engineFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$p is inside the engine install. This script never writes there; pick another folder."
        }
    }

    Note 'Indexing what your engine install contains (takes a minute the first time)...'
    $engineRel = @(Get-RelPaths $EngineDir @('Engine/Plugins', 'Engine/Source') @('.uplugin', '.Build.cs'))
    $EngineIdx = New-TreeIndex $engineRel
    $EngineDllNames = New-Set
    foreach ($f in (Get-FilesFast (P $EngineDir 'Engine' 'Binaries' 'Win64') 'UnrealEditor-*.dll')) {
        [void]$EngineDllNames.Add(([System.IO.Path]::GetFileNameWithoutExtension($f)).Substring('UnrealEditor-'.Length))
    }
    $pluginUsableCache = @{}
    function Test-EnginePluginUsable([string]$Name) {
        if ($pluginUsableCache.ContainsKey($Name)) { return $pluginUsableCache[$Name] }
        $ok = $false
        if ($EngineIdx.PluginFile.ContainsKey($Name)) {
            $file = P $EngineDir (To-Native $EngineIdx.PluginFile[$Name])
            $desc = Read-Json $file
            if ((As-Array (Get-Prop $desc 'Modules')).Count -eq 0) { $ok = $true }
            else {
                $bin = P (Split-Path -Parent $file) 'Binaries' 'Win64'
                $ok = (@(Get-FilesFast $bin 'UnrealEditor-*.dll').Count -gt 0)
            }
        }
        $pluginUsableCache[$Name] = $ok
        return $ok
    }
    function Get-EngineModuleState([string]$Name, [bool]$LinkNeeded) {
        if (-not $EngineIdx.Modules.ContainsKey($Name)) { return 'missing' }
        $m = $EngineIdx.Modules[$Name]
        if (-not $LinkNeeded) { return 'ok' }
        if ($m.Plugin) { if (Test-EnginePluginUsable $m.Plugin) { return 'ok' } else { return 'stripped' } }
        if ([System.IO.File]::ReadAllText((P $EngineDir (To-Native $m.BuildCs))) -match 'ModuleType\.External') { return 'ok' }
        if ($EngineDllNames.Contains($Name)) { return 'ok' }
        return 'stripped'
    }
    # The CSS install keeps some of Epic's plugins as source only, with nothing compiled (OpenXRHandTracking,
    # OpenXREyeTracker, LiveLink). The editor uses one plugin per name, and between an engine plugin and a mod with the
    # same version number it keeps the engine's copy, which can't load. So such a mod gets a version number above the
    # engine copy's. Returns $true when it changed the descriptor.
    function Set-VersionAboveEngine($Desc, [string]$Name) {
        if (-not $EngineIdx.PluginFile.ContainsKey($Name)) { return $false }
        $ev = 0
        try { $v = Get-Prop (Read-Json (P $EngineDir (To-Native $EngineIdx.PluginFile[$Name]))) 'Version'; if ($null -ne $v) { $ev = [int]$v } } catch { }
        $mv = 0
        try { $v = Get-Prop $Desc 'Version'; if ($null -ne $v) { $mv = [int]$v } } catch { }
        if ($mv -gt $ev) { return $false }
        Set-Prop $Desc 'Version' ($ev + 1)
        return $true
    }
    $hasPython = ($EngineIdx.Plugins.ContainsKey('PythonScriptPlugin') -and (Test-EnginePluginUsable 'PythonScriptPlugin'))
    Ok ("Engine has {0} plugins and {1} modules; Python editor scripting: {2}" -f $EngineIdx.Plugins.Count, $EngineIdx.Modules.Count, $(if ($hasPython) { 'YES' } else { 'NO' }))

    # ------------------------------------------------------- SML templates ---
    $exampleFile = $null
    foreach ($f in (Get-FilesFast (P $ProjectDir 'Mods') 'ExampleMod.uplugin')) { $exampleFile = $f; break }
    $exampleDesc = $null; $smlDep = $null; $gameVersion = $null
    if ($exampleFile) {
        $exampleDesc = Read-Json $exampleFile
        $gameVersion = Get-Prop $exampleDesc 'GameVersion'
        foreach ($d in (As-Array (Get-Prop $exampleDesc 'Plugins'))) { if ((Get-Prop $d 'Name') -eq 'SML') { $smlDep = $d } }
        Ok "Using ExampleMod's descriptor as the SML template ($exampleFile)"
    } else {
        Warn 'ExampleMod not found under Mods. Using default SML fields; check the NativeVR .uplugin before packaging.'
    }
    if (-not $smlDep) {
        $smlVer = '3.12.0'
        foreach ($f in (Get-FilesFast (P $ProjectDir 'Mods') 'SML.uplugin')) { $sv = Get-Prop (Read-Json $f) 'SemVersion'; if ($sv) { $smlVer = $sv }; break }
        $parts = (Get-SemVer $smlVer).Split('.')
        $smlDep = [pscustomobject]@{ Name = 'SML'; Enabled = $true; SemVersion = ('^{0}.{1}.0' -f $parts[0], $parts[1]) }
    }

    # ------------------------------------------------------------- git ---
    $UseLocal = $false
    if ($SourceDir) {
        $SourceDir = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd($Sep)
        $UseLocal = $true
    } elseif ($OnWindows) {
        # A previous source build of the 5.6 engine on this PC saves a big download.
        $cands = New-Object System.Collections.Generic.List[string]
        try { $bk = Get-ItemProperty -Path 'HKCU:\Software\Epic Games\Unreal Engine\Builds' -ErrorAction Stop; foreach ($pp in $bk.PSObject.Properties) { if ($pp.Name -notlike 'PS*') { $cands.Add([string]$pp.Value) } } } catch { }
        $cands.Add('C:\UnrealEngine-5.6.1-CSS')
        foreach ($c in $cands) {
            try { if (-not $c -or -not (Test-Path -LiteralPath (P $c 'Setup.bat'))) { continue } } catch { continue }
            $ver = P $c 'Engine' 'Build' 'Build.version'
            $tpl = P $c 'Templates' 'TP_VirtualRealityBP' 'Content'
            if ((Test-Path -LiteralPath $ver) -and (Test-Path -LiteralPath $tpl)) {
                $bv = Read-Json $ver
                if ((Get-Prop $bv 'MajorVersion') -eq 5 -and (Get-Prop $bv 'MinorVersion') -eq 6 -and @(Get-FilesFast $tpl '*.uasset').Count -gt 0) {
                    $SourceDir = $c.TrimEnd($Sep); $UseLocal = $true; break
                }
            }
        }
    }

    $Repo = $null; $SourceRoot = $null; $SourceDesc = $null
    $Deps = $null
    $ManifestDir = P $CacheDir 'gitdeps'
    $DlTemp = P $CacheDir 'download-temp'
    $TemplateRel = 'Templates/TP_VirtualRealityBP'

    if ($UseLocal) {
        Step "Using the engine source already on this PC: $SourceDir"
        $SourceRoot = $SourceDir
        $SourceDesc = "local source folder $SourceDir"
        $srcRel = @(Get-RelPaths $SourceRoot @('Engine/Plugins', 'Engine/Source') @('.uplugin', '.Build.cs'))
        $SrcIdx = New-TreeIndex $srcRel
        if (-not (Test-Path -LiteralPath (P $SourceRoot (To-Native $TemplateRel)))) { throw "$SourceDir has no Templates\TP_VirtualRealityBP folder." }
    } else {
        Step 'Getting the needed parts of the CSS engine source from GitHub'
        $gitVer = @(Invoke-Native 'git' @('--version'))[0]
        if ($gitVer -notmatch '(\d+)\.(\d+)') { throw 'git was not found. Install Git for Windows from https://git-scm.com and run this again.' }
        if ([int]$Matches[1] -lt 2 -or ([int]$Matches[1] -eq 2 -and [int]$Matches[2] -lt 27)) { throw "Your git ($gitVer) is too old for partial downloads. Update Git for Windows and run this again." }
        Ok $gitVer
        $Repo = P $CacheDir 'UnrealEngine'
        $branchFile = P $CacheDir 'branch.txt'
        if (-not (Test-Path -LiteralPath (P $Repo '.git'))) {
            if (-not $Branch) {
                Note 'Asking GitHub for the engine branches (a sign-in window may open; your GitHub account must be linked to Epic and to ficsit.app, same as for the engine installer)...'
                $lines = @(Invoke-Native 'git' @('ls-remote', '--heads', '--tags', $RepoUrl) -AllowFail)
                if ($S.LastExit -ne 0) {
                    throw ("GitHub refused access to $RepoUrl.`n{0}`nThis repo is private: link your GitHub account to your Epic account and to ficsit.app (the same steps as downloading the CSS engine installer), then run this again." -f ($S.LastStderr -join "`n"))
                }
                $refs = New-Object System.Collections.Generic.List[string]
                foreach ($l in $lines) { if ($l -match '^[0-9a-fA-F]{40}\s+refs/(heads|tags)/(.+?)(\^\{\})?$') { if (-not $refs.Contains($Matches[2])) { $refs.Add($Matches[2]) } } }
                $cands = @($refs | Where-Object { $_ -match '5\.6\.1' -and $_ -match 'css' })
                $exact = @($cands | Where-Object { $_ -ieq '5.6.1-css' })
                if ($exact.Count -ge 1) { $Branch = $exact[0] }
                elseif ($cands.Count -eq 1) { $Branch = $cands[0] }
                else {
                    $def = $null
                    foreach ($l in @(Invoke-Native 'git' @('ls-remote', '--symref', $RepoUrl, 'HEAD') -AllowFail)) { if ($l -match '^ref:\s+refs/heads/(\S+)\s+HEAD') { $def = $Matches[1] } }
                    if ($def -and ($cands -contains $def)) { $Branch = $def }
                    else {
                        $show = @($refs | Where-Object { $_ -match 'css|5\.6' } | Select-Object -First 40)
                        throw ("Couldn't pick the 5.6.1 CSS branch by itself. Branches and tags that look related:`n  {0}`nRun again with -Branch <name>." -f ($show -join "`n  "))
                    }
                }
            }
            Ok "Branch: $Branch"
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
            Note 'Downloading the file list only (no engine files yet)...'
            Invoke-GitLive @('-c', 'core.longpaths=true', 'clone', '--filter=blob:none', '--no-checkout', '--depth', '1', '--branch', $Branch, $RepoUrl, $Repo)
            [void](Invoke-Native 'git' @('-C', $Repo, 'config', 'core.longpaths', 'true'))
            Write-TextFile $branchFile $Branch
        } else {
            $had = ''
            if (Test-Path -LiteralPath $branchFile) { $had = ([System.IO.File]::ReadAllText($branchFile)).Trim() }
            if ($Branch -and $had -and ($Branch -ne $had)) { throw "The download cache at $CacheDir holds branch '$had', not '$Branch'. Delete that folder or pass a different -CacheDir." }
            $Branch = $had
            Ok "Reusing the earlier download in $Repo (branch $Branch)"
        }
        $commit = @(Invoke-Native 'git' @('-C', $Repo, 'rev-parse', '--short', 'HEAD'))[0]
        $SourceRoot = $Repo
        $SourceDesc = "$RepoUrl, branch $Branch, commit $commit"

        $tplCheck = @(Invoke-Native 'git' @('-C', $Repo, 'ls-tree', '--name-only', 'HEAD', ($TemplateRel + '/')))
        if (@($tplCheck).Count -eq 0) {
            throw "Branch $Branch doesn't contain Templates/TP_VirtualRealityBP. Point -SourceDir at an Epic Launcher UE 5.6 install instead (it has the template), or ask Claude."
        }
        if (-not (Test-Path -LiteralPath (P $Repo (To-Native $TemplateRel)))) {
            Note 'Getting the VR Template folder...'
            if (Test-Path -LiteralPath (P $Repo '.git' 'info' 'sparse-checkout')) {
                Invoke-GitLive @('-C', $Repo, 'sparse-checkout', 'add', $TemplateRel)
            } else {
                Invoke-GitLive @('-C', $Repo, 'sparse-checkout', 'set', '--cone', $TemplateRel)
                Invoke-GitLive @('-C', $Repo, 'checkout', '--quiet', 'HEAD')
            }
            if (-not (Test-Path -LiteralPath (P $Repo (To-Native $TemplateRel)))) {
                Invoke-GitLive @('-C', $Repo, 'read-tree', '-mu', 'HEAD')
            }
        }
        Ok 'VR Template folder downloaded'

        Note 'Indexing plugins and modules in the engine source...'
        $treeLines = @(Invoke-Native 'git' @('-C', $Repo, '-c', 'core.quotePath=false', 'ls-tree', '-r', '--name-only', 'HEAD', '--', 'Engine/Plugins', 'Engine/Source'))
        $srcRel = @($treeLines -match '(\.uplugin|\.Build\.cs)$')
        $SrcIdx = New-TreeIndex $srcRel
        Ok ("Source has {0} plugins and {1} modules" -f $SrcIdx.Plugins.Count, $SrcIdx.Modules.Count)

        $manifests = @(@(Invoke-Native 'git' @('-C', $Repo, 'ls-tree', '--name-only', 'HEAD', 'Engine/Build/')) -match '\.gitdeps\.xml$')
        if ($manifests.Count -eq 0) { throw 'No Engine/Build/*.gitdeps.xml in this branch, so the template art and maps cannot be located.' }
        $manifestPaths = New-Object System.Collections.Generic.List[string]
        foreach ($m in $manifests) {
            $dest = P $ManifestDir ($m.Substring($m.LastIndexOf('/') + 1))
            if (-not (Test-Path -LiteralPath $dest)) { Save-GitBlob $Repo $m $dest }
            $manifestPaths.Add($dest)
        }
        Note 'Reading the binary file list...'
        $Deps = Read-GitDeps $manifestPaths.ToArray() @(($TemplateRel + '/'), 'Templates/TemplateResources/', 'Engine/Plugins/', 'Engine/Source/', 'Engine/Binaries/ThirdParty/')
        Step 'Downloading the VR Template art, maps and Blueprints'
        [void](Invoke-GitDepsFetch $Deps $Repo @(($TemplateRel + '/')) $DlTemp)
    }

    # Shared content packs: Epic's project wizard copies these in next to the template's own content (the template's
    # TemplateDefs.ini lists them). The template map and Blueprints use their floor, cubes and pistol mesh.
    $SharedPacks = New-Object System.Collections.Generic.List[object]
    foreach ($sp in (Read-SharedPackDefs (P $SourceRoot (To-Native $TemplateRel)))) {
        $chosen = $null
        foreach ($lvl in $sp.Levels) {
            $rel = "Templates/TemplateResources/$lvl/$($sp.Mount)"
            if ($UseLocal) { if (Test-Path -LiteralPath (P $SourceRoot (To-Native $rel) 'Content')) { $chosen = $rel } }
            else { foreach ($k in $Deps.Files.Keys) { if ($k.StartsWith("$rel/Content/", [System.StringComparison]::OrdinalIgnoreCase)) { $chosen = $rel; break } } }
            if ($chosen) { break }
        }
        if ($chosen) { $SharedPacks.Add([pscustomobject]@{ Mount = $sp.Mount; Rel = $chosen }) }
        else { Warn "The template uses the shared content pack '$($sp.Mount)', but the engine source doesn't have it." }
    }
    if ($SharedPacks.Count -gt 0) {
        $packNames = @($SharedPacks | ForEach-Object { $_.Mount }) -join ', '
        if (-not $UseLocal) {
            Step "Downloading the shared content the template uses: $packNames"
            [void](Invoke-GitDepsFetch $Deps $Repo @($SharedPacks | ForEach-Object { $_.Rel + '/Content/' }) $DlTemp)
        } else { Ok "Shared content the template uses: $packNames" }
    }

    $TemplateDir = P $SourceRoot (To-Native $TemplateRel)
    $TemplateContent = P $TemplateDir 'Content'
    $tplAssetFiles = @(Get-FilesFast $TemplateContent '*.uasset')
    $tplAssets = $tplAssetFiles.Count
    if ($tplAssets -eq 0) { throw "The VR Template has no assets at $TemplateContent. The download didn't complete; run the script again." }
    $probe = [System.IO.File]::ReadAllBytes($tplAssetFiles[0])
    if ($probe.Length -lt 200 -and [System.Text.Encoding]::ASCII.GetString($probe).StartsWith('version https://git-lfs')) {
        throw 'The template assets are Git LFS placeholders. Run "git lfs install" once, then run this script again.'
    }
    Ok "VR Template ready: $tplAssets assets"

    # -------------------------------------------- work out needed plugins ---
    Step 'Working out which plugins the VR Template uses'
    $tplUproject = @(Get-FilesFast $TemplateDir '*.uproject') | Select-Object -First 1
    if (-not $tplUproject) { throw "No .uproject file in $TemplateDir." }
    $Need = [ordered]@{}
    function Add-Need([string]$Name, [string]$Why) { if ($Name -and $Name -ne 'SML' -and -not $Need.Contains($Name)) { $Need[$Name] = $Why } }
    $SkipSet = New-Set
    foreach ($x in $SkipPlugins) { if ($ExtraPlugins -notcontains $x) { [void]$SkipSet.Add($x) } }
    # Modules the project already has (in its mods, plugins or Source), e.g. ones added to a mod for NativeVR.
    $ProjectModules = New-Set
    foreach ($r in @(Get-RelPaths $ProjectDir @('Mods', 'Plugins', 'Source') @('.Build.cs'))) {
        $fn = $r.Substring($r.LastIndexOf('/') + 1)
        [void]$ProjectModules.Add($fn.Substring(0, $fn.Length - '.Build.cs'.Length))
    }
    foreach ($e in (As-Array (Get-Prop (Read-Json $tplUproject) 'Plugins'))) {
        if ((Get-Prop $e 'Enabled') -ne $true) { continue }
        if (-not (Test-AllowsWin64 $e)) { continue }
        $tal = As-Array (Get-Prop $e 'TargetAllowList')
        if ($tal.Count -gt 0 -and -not ($tal -contains 'Game' -or $tal -contains 'Client')) { Note "Skipping $(Get-Prop $e 'Name') (editor-only in the template)"; continue }
        Add-Need (Get-Prop $e 'Name') 'enabled in the VR Template project'
    }
    $refs = Get-AssetReferences $TemplateContent
    foreach ($sp in $SharedPacks) {
        $pr = Get-AssetReferences (P $SourceRoot (To-Native $sp.Rel) 'Content')
        foreach ($x in $pr.Modules) { [void]$refs.Modules.Add($x) }
        foreach ($x in $pr.Mounts) { [void]$refs.Mounts.Add($x) }
    }
    $MissingEngineModules = New-Set
    foreach ($mod in $refs.Modules) {
        if ($SrcIdx.Modules.ContainsKey($mod) -and $SrcIdx.Modules[$mod].Plugin) { Add-Need $SrcIdx.Modules[$mod].Plugin "template assets use its C++ module $mod" }
        elseif ($EngineIdx.Modules.ContainsKey($mod) -and $EngineIdx.Modules[$mod].Plugin) { Add-Need $EngineIdx.Modules[$mod].Plugin "template assets use its C++ module $mod" }
        elseif ((Get-EngineModuleState $mod $true) -ne 'ok' -and $SrcIdx.Modules.ContainsKey($mod) -and -not $ProjectModules.Contains($mod)) { [void]$MissingEngineModules.Add($mod) }
    }
    foreach ($mount in $refs.Mounts) {
        if ($SrcIdx.Plugins.ContainsKey($mount) -or $EngineIdx.Plugins.ContainsKey($mount)) { Add-Need $mount "template assets use its content (/$mount/)" }
    }
    foreach ($x in $ExtraPlugins) { Add-Need $x 'requested with -ExtraPlugins' }
    $DirectNeeds = @($Need.Keys)

    # Classify every needed plugin, following each plugin's own dependencies.
    $ToFetch = [ordered]@{}        # name -> rel dir in source
    $FromEngine = [ordered]@{}     # name -> reason
    $Skipped = [ordered]@{}        # name -> reason
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($n in $DirectNeeds) { $queue.Enqueue($n) }
    $seen = New-Set
    $descCache = @{}
    function Get-SourceDesc([string]$Name) {
        if ($descCache.ContainsKey($Name)) { return $descCache[$Name] }
        $rel = $SrcIdx.PluginFile[$Name]
        $path = P $SourceRoot (To-Native $rel)
        if (-not (Test-Path -LiteralPath $path)) { $path = P $CacheDir 'descriptors' "$Name.uplugin"; if (-not (Test-Path -LiteralPath $path)) { Save-GitBlob $Repo $rel $path } }
        $d = Read-Json $path
        $descCache[$Name] = $d
        return $d
    }
    while ($queue.Count -gt 0) {
        $name = $queue.Dequeue()
        if (-not $seen.Add($name)) { continue }
        if ($SkipSet.Contains($name)) { $Skipped[$name] = 'left out for now (-SkipPlugins)'; continue }
        $why = 'needed by another plugin'
        if ($Need.Contains($name)) { $why = $Need[$name] }
        if ($EngineIdx.Plugins.ContainsKey($name) -and (Test-EnginePluginUsable $name)) {
            $desc = Read-Json (P $EngineDir (To-Native $EngineIdx.PluginFile[$name]))
            if (Test-EditorOnlyPlugin $desc) { $Skipped[$name] = 'editor-only, already in your engine' } else { $FromEngine[$name] = $why }
            continue
        }
        if (-not $SrcIdx.Plugins.ContainsKey($name)) {
            if ($DirectNeeds -contains $name) { Warn "Plugin '$name' isn't in your engine or the engine source. ($why)" }
            $Skipped[$name] = 'not found anywhere'
            continue
        }
        $desc = Get-SourceDesc $name
        if (Test-EditorOnlyPlugin $desc) { $Skipped[$name] = 'editor-only, not needed for the mod'; Warn "Editor-only plugin '$name' is missing from your engine; the template may show a harmless warning about it."; continue }
        $ToFetch[$name] = $SrcIdx.Plugins[$name]
        foreach ($d in (As-Array (Get-Prop $desc 'Plugins'))) {
            $dn = [string](Get-Prop $d 'Name')
            if (-not $dn -or $dn -eq 'SML') { continue }
            if ((Get-Prop $d 'Enabled') -eq $false) { continue }
            if (-not (Test-AllowsWin64 $d)) { continue }
            if ((Get-Prop $d 'Optional') -eq $true -and -not ($EngineIdx.Plugins.ContainsKey($dn) -or $SrcIdx.Plugins.ContainsKey($dn))) { continue }
            $queue.Enqueue($dn)
        }
    }
    foreach ($k in $ToFetch.Keys) { Ok ("Fetch from source: {0}  ({1})" -f $k, $(if ($Need.Contains($k)) { $Need[$k] } else { 'needed by another plugin' })) }
    foreach ($k in $FromEngine.Keys) { Ok "Already in your engine: $k" }
    foreach ($k in $Skipped.Keys) { Note "Skipped $k ($($Skipped[$k]))" }
    $TrackingSkipped = ($Skipped.Contains('OpenXRHandTracking') -or $Skipped.Contains('OpenXREyeTracker'))
    if ($TrackingSkipped) { Note 'Hand or eye tracking is left out. The template will show a "Missing Plugins" prompt for it: click Dismiss, never Enable Missing (that switches on the engine''s uncompiled copy and the editor won''t start).' }
    if ($ToFetch.Count -eq 0) { Note 'Your engine already has every plugin the template needs.' }

    # Download the plugin folders.
    if (-not $UseLocal -and $ToFetch.Count -gt 0) {
        Step 'Downloading the plugin source folders'
        Invoke-GitLive (@('-C', $Repo, 'sparse-checkout', 'add') + @($ToFetch.Values))
        $descCache = @{}
    }

    # Check every C++ module those plugins link against.
    Step 'Checking what those plugins need from the engine'
    $FetchedModules = New-Set
    foreach ($pn in $ToFetch.Keys) {
        $dir = $ToFetch[$pn]
        foreach ($m in $SrcIdx.Modules.Keys) { $mm = $SrcIdx.Modules[$m]; if ($mm.Dir.StartsWith($dir + '/') -or $mm.Dir -eq $dir) { [void]$FetchedModules.Add($m) } }
    }
    # The fetched plugins a fetched plugin depends on, directly or through others (read from their .uplugin files).
    function Get-PluginNeeds([string]$Name) {
        $out = New-Set
        $todo = New-Object System.Collections.Generic.Queue[string]
        $todo.Enqueue($Name)
        while ($todo.Count -gt 0) {
            $n = $todo.Dequeue()
            if (-not $ToFetch.Contains($n)) { continue }
            foreach ($d in (As-Array (Get-Prop (Get-SourceDesc $n) 'Plugins'))) {
                $dn = [string](Get-Prop $d 'Name')
                if ($dn -and $out.Add($dn)) { $todo.Enqueue($dn) }
            }
        }
        return ,$out
    }
    # An engine module the CSS install lacks goes into the mod of a plugin that uses it: the one every other user
    # depends on. LiveLinkAnimationCore goes into LiveLink, because OpenXRHandTracking depends on LiveLink.
    function Find-HostPlugin([string[]]$Users) {
        $users = @($Users | Where-Object { $_ } | Select-Object -Unique)
        if ($users.Count -eq 0) { return $null }
        foreach ($h in @($ToFetch.Keys)) {
            if ($users -notcontains $h) { continue }
            $all = $true
            foreach ($u in $users) { if ($u -ne $h -and -not (Get-PluginNeeds $u).Contains($h)) { $all = $false; break } }
            if ($all) { return $h }
        }
        return $null
    }
    $Stripped = [ordered]@{}   # module -> the modules that need it
    $Missing = [ordered]@{}
    $Vendor = [ordered]@{}     # engine module -> where it goes: copied unchanged into that plugin's mod
    $NeededBy = @{}            # module -> the plugins (mods) whose modules need it
    $scan = New-Object System.Collections.Generic.List[object]
    foreach ($pn in $ToFetch.Keys) {
        foreach ($bc in (Get-BuildCsFiles (P $SourceRoot (To-Native $ToFetch[$pn])))) { $scan.Add([pscustomobject]@{ File = $bc; Plugin = $pn }) }
    }
    $round = 0
    while ($scan.Count -gt 0 -and $round -lt 5) {
        $round++
        foreach ($sc in $scan) {
            $owner = ([System.IO.Path]::GetFileName($sc.File)) -replace '\.Build\.cs$', ''
            $bcDeps = Get-BuildCsDeps $sc.File
            foreach ($pair in @(@($bcDeps.Link, $true), @($bcDeps.Include, $false))) {
                foreach ($d in $pair[0]) {
                    if ($FetchedModules.Contains($d) -or $ProjectModules.Contains($d) -or $Vendor.Contains($d)) { continue }
                    $state = Get-EngineModuleState $d $pair[1]
                    if ($state -eq 'ok') { continue }
                    if ($SrcIdx.Modules.ContainsKey($d) -and $SrcIdx.Modules[$d].Plugin -and $ToFetch.Contains($SrcIdx.Modules[$d].Plugin)) { continue }
                    $tbl = $Missing; if ($state -eq 'stripped') { $tbl = $Stripped }
                    if (-not $tbl.Contains($d)) { $tbl[$d] = New-Set }
                    [void]$tbl[$d].Add($owner)
                    if (-not $NeededBy.ContainsKey($d)) { $NeededBy[$d] = New-Set }
                    [void]$NeededBy[$d].Add($sc.Plugin)
                }
            }
        }
        # Engine modules (not part of a plugin) that the CSS install has as source but didn't compile get copied into a
        # mod; then their own needs are checked the same way. Modules missing from the install altogether are only
        # reported: Coffee Stain left those out on purpose (other platforms, or not used by the game).
        $scan = New-Object System.Collections.Generic.List[object]
        $newDirs = New-Object System.Collections.Generic.List[string]
        foreach ($m in @($Stripped.Keys)) {
            if ($Vendor.Contains($m) -or -not $SrcIdx.Modules.ContainsKey($m)) { continue }
            $mm = $SrcIdx.Modules[$m]
            if ($mm.Plugin -or $mm.Dir -notmatch '^Engine/Source/(Runtime|Developer|Editor)/') { continue }
            $hostName = Find-HostPlugin @($NeededBy[$m])
            if (-not $hostName) { continue }
            $type = 'Runtime'
            if ($mm.Dir -match '^Engine/Source/Editor/') { $type = 'Editor' } elseif ($mm.Dir -match '^Engine/Source/Developer/') { $type = 'DeveloperTool' }
            $Vendor[$m] = [pscustomobject]@{ Host = $hostName; Dir = $mm.Dir; Type = $type }
            $newDirs.Add($mm.Dir)
        }
        if ($newDirs.Count -gt 0) {
            if (-not $UseLocal) { Invoke-GitLive (@('-C', $Repo, 'sparse-checkout', 'add') + @($newDirs)) }
            foreach ($m in @($Vendor.Keys)) {
                $v = $Vendor[$m]
                if (-not $newDirs.Contains($v.Dir)) { continue }
                foreach ($bc in (Get-BuildCsFiles (P $SourceRoot (To-Native $v.Dir)))) { $scan.Add([pscustomobject]@{ File = $bc; Plugin = $v.Host }) }
            }
        }
    }
    foreach ($m in $MissingEngineModules) { if (-not $Missing.Contains($m) -and -not $Stripped.Contains($m)) { $Missing[$m] = New-Set; [void]$Missing[$m].Add('template assets') } }
    # The OpenXR SDK (Khronos' headers and loader) is a third-party engine module the CSS install leaves out entirely,
    # and Epic's OpenXR plugins don't build without it. It goes into the OpenXR mod (see the placement step).
    $SdkVendor = [ordered]@{}
    if ($Missing.Contains('OpenXR') -and $SrcIdx.Modules.ContainsKey('OpenXR') -and $SrcIdx.Modules['OpenXR'].Dir -eq 'Engine/Source/ThirdParty/OpenXR') {
        $sdkHost = Find-HostPlugin @($NeededBy['OpenXR'])
        if ($sdkHost) { $SdkVendor['OpenXR'] = [pscustomobject]@{ Host = $sdkHost; Dir = 'Engine/Source/ThirdParty/OpenXR'; BinDir = 'Engine/Binaries/ThirdParty/OpenXR' } }
    }
    $Gaps = New-Object System.Collections.Generic.List[object]
    foreach ($kind in @('missing', 'stripped')) {
        $tbl = $Missing
        $label = 'missing'
        if ($kind -eq 'stripped') { $tbl = $Stripped; $label = 'present but not compiled' }
        foreach ($m in @($tbl.Keys)) {
            $dir = $null; $plug = $null
            if ($SrcIdx.Modules.ContainsKey($m)) { $dir = $SrcIdx.Modules[$m].Dir; $plug = $SrcIdx.Modules[$m].Plugin }
            $Gaps.Add([pscustomobject]@{ Module = $m; State = $label; UsedBy = (@($tbl[$m]) -join ', '); Dir = $dir; Plugin = $plug })
        }
    }
    $RefDirs = New-Object System.Collections.Generic.List[string]
    $VendorDirs = New-Object System.Collections.Generic.List[string]
    $gapLines = New-Object System.Collections.Generic.List[string]
    foreach ($g in $Gaps) {
        if ($Vendor.Contains($g.Module)) {
            $hn = $Vendor[$g.Module].Host
            Ok ("Engine module {0} is {1} in your CSS install (used by {2}): its source goes into the {3} mod, unchanged" -f $g.Module, $g.State, $g.UsedBy, $hn)
            $gapLines.Add(("- {0}: {1} in the CSS install, used by {2}. Copied unchanged from ``{3}`` into the {4} mod and listed in ``{4}.uplugin``." -f $g.Module, $g.State, $g.UsedBy, $g.Dir, $hn))
            if (-not $VendorDirs.Contains($g.Dir)) { $VendorDirs.Add($g.Dir) }
            continue
        }
        if ($SdkVendor.Contains($g.Module)) {
            $sv = $SdkVendor[$g.Module]
            Ok ("The OpenXR SDK (module {0}: Khronos' headers and loader) is {1} in your CSS install (used by {2}): it goes into the {3} mod" -f $g.Module, $g.State, $g.UsedBy, $sv.Host)
            $gapLines.Add(("- {0} (the OpenXR SDK): {1} in the CSS install, used by {2}. Copied from ``{3}`` and ``{4}`` into the {5} mod as ``Source\ThirdParty\{0}``, with its build rules pointed at the mod's folder." -f $g.Module, $g.State, $g.UsedBy, $sv.Dir, $sv.BinDir, $sv.Host))
            if (-not $VendorDirs.Contains($sv.Dir)) { $VendorDirs.Add($sv.Dir) }
            continue
        }
        if (-not $g.Dir) {
            Note ("Module {0} (used by {1}) isn't in your engine or the source; probably for another platform." -f $g.Module, $g.UsedBy)
            continue
        }
        if ($g.Plugin) {
            Warn ("Module {0} is {1} in your CSS install (used by {2}). It belongs to plugin {3}; re-run with -ExtraPlugins {3} if the build asks for it." -f $g.Module, $g.State, $g.UsedBy, $g.Plugin)
            $gapLines.Add(("- {0}: {1} in the CSS install, used by {2}. Part of plugin {3} (re-run the setup script with ``-ExtraPlugins {3}``)." -f $g.Module, $g.State, $g.UsedBy, $g.Plugin))
        } else {
            Warn ("Engine module {0} is {1} in your CSS install (used by {2}). Source downloaded for reference: {3}" -f $g.Module, $g.State, $g.UsedBy, $g.Dir)
            $gapLines.Add(("- {0}: {1} in the CSS install, used by {2}. Reference source: ``{3}`` (not wired into the project yet)." -f $g.Module, $g.State, $g.UsedBy, $g.Dir))
            if (-not $RefDirs.Contains($g.Dir)) { $RefDirs.Add($g.Dir) }
        }
    }
    if ($gapLines.Count -eq 0) { Ok 'Every engine module those plugins use is in your install'; $gapLines.Add('- None found. If the build still fails, read the build log.') }
    if (-not $UseLocal -and $RefDirs.Count -gt 0) {
        Note 'Downloading source of those engine modules for reference (they are NOT added to the project automatically)...'
        Invoke-GitLive (@('-C', $Repo, 'sparse-checkout', 'add') + @($RefDirs))
    }

    if (-not $UseLocal) {
        $prefixes = New-Object System.Collections.Generic.List[string]
        foreach ($d in $ToFetch.Values) { $prefixes.Add($d + '/') }
        foreach ($d in $VendorDirs) {
            $prefixes.Add($d + '/')
            if ($d -match '/ThirdParty/([^/]+)$') { $prefixes.Add("Engine/Binaries/ThirdParty/$($Matches[1])/") }
        }
        foreach ($d in $RefDirs) {
            $prefixes.Add($d + '/')
            if ($d -match '/ThirdParty/([^/]+)$') { $prefixes.Add("Engine/Binaries/ThirdParty/$($Matches[1])/") }
        }
        if ($prefixes.Count -gt 0) {
            Step 'Downloading binary files those folders need'
            [void](Invoke-GitDepsFetch $Deps $Repo $prefixes.ToArray() $DlTemp)
        }
    }

    # ------------------------------------------------- place into project ---
    Step 'Placing everything into your project'
    $ModsDir = P $ProjectDir 'Mods'
    $ContentDir = P $ProjectDir 'Content'
    $StateFile = P $LogDir 'state.json'
    $FirstRun = $Fresh -or -not (Test-Path -LiteralPath $StateFile)
    if ($FirstRun) { Note 'First run: old copies of Epic''s plugins and template placed below are moved to _NativeVR_Backup first (a clean start). Your NativeVR mods stay.' }
    else { Note 'Re-run: only adding what is missing. Existing NativeVR work, plugin mods and CLAUDE.md are left alone (use -Fresh to start over).' }

    # Which plugins already exist as project plugins (Mods or Plugins folders)?
    $ProjectPlugins = @{}
    foreach ($root in @($ModsDir, (P $ProjectDir 'Plugins'))) {
        foreach ($up in @(Get-FilesFast $root '*.uplugin')) {
            $n = [System.IO.Path]::GetFileNameWithoutExtension($up)
            if (-not $ProjectPlugins.ContainsKey($n)) { $ProjectPlugins[$n] = Split-Path -Parent $up }
        }
    }
    $BackedUpPlugins = @{}
    if ($FirstRun) {
        # Epic's plugins this run places (fresh copies) and plugins left out on purpose (-SkipPlugins). NativeVR's own mod
        # stays: it is real work (it may come from the GitHub repo), and below only gets the dependencies it lacks.
        foreach ($n in (@($ToFetch.Keys) + @($SkipSet))) {
            if ($ProjectPlugins.ContainsKey($n)) {
                $oldDir = $ProjectPlugins[$n]
                Backup-Item $oldDir $ProjectDir
                $BackedUpPlugins[$n] = P $S.BackupRoot ($oldDir.Substring($ProjectDir.TrimEnd($Sep).Length).TrimStart($Sep))
                $ProjectPlugins.Remove($n)
            }
        }
        foreach ($f in @('CLAUDE.md', (P '.claude' 'settings.json'))) { Backup-Item (P $ProjectDir $f) $ProjectDir }
    }

    # Epic's plugins, each as its own mod in Mods.
    foreach ($name in $ToFetch.Keys) {
        if ($ProjectPlugins.ContainsKey($name)) {
            $have = P $ProjectPlugins[$name] "$name.uplugin"
            $haveRel = $ProjectPlugins[$name].Substring($ProjectDir.Length + 1)
            if (Test-Path -LiteralPath $have) {
                $hd = Read-Json $have
                if (Set-VersionAboveEngine $hd $name) { Save-Json $hd $have; Ok "$haveRel kept; its .uplugin version is now above the engine's uncompiled copy, so the editor loads the mod" }
            }
            Note "$name is already in the project ($haveRel); left as is"
            continue
        }
        $src = P $SourceRoot (To-Native $ToFetch[$name])
        $dst = P $ModsDir $name
        Copy-Tree $src $dst -ExcludeDirs @((P $src 'Intermediate'), (P $src 'Binaries' 'Win64'), (P $src 'Saved'))
        $upf = P $dst "$name.uplugin"
        $d = Read-Json $upf
        Set-Prop $d 'SemVersion' (Get-SemVer ([string](Get-Prop $d 'VersionName')))
        if ($gameVersion) { Set-Prop $d 'GameVersion' $gameVersion }
        Set-Prop $d 'EnabledByDefault' $true
        Set-Prop $d 'RequiredOnRemote' $false
        Remove-Prop $d 'SupportedPrograms'
        foreach ($m in (As-Array (Get-Prop $d 'Modules'))) { Remove-Prop $m 'ProgramAllowList' }
        $plist = New-Object System.Collections.Generic.List[object]
        $hasSml = $false
        foreach ($e in (As-Array (Get-Prop $d 'Plugins'))) { $plist.Add($e); if ((Get-Prop $e 'Name') -eq 'SML') { $hasSml = $true } }
        if (-not $hasSml) { $plist.Add($smlDep) }
        Set-Prop $d 'Plugins' ([object[]]$plist.ToArray())
        $bumped = Set-VersionAboveEngine $d $name
        if ($BackedUpPlugins.ContainsKey($name)) { Restore-AddedModules $BackedUpPlugins[$name] $dst $d $name }
        Save-Json $d $upf
        $ProjectPlugins[$name] = $dst
        if ($bumped) { Ok "Mods\$name (Epic's code unchanged; SML fields added to its .uplugin, and a version above the engine's uncompiled copy)" }
        else { Ok "Mods\$name (Epic's code unchanged; SML fields added to its .uplugin)" }
    }

    # Engine modules the CSS install lacks: copied unchanged into the mod that uses them and listed in its .uplugin,
    # so the editor build compiles them along with it.
    foreach ($m in @($Vendor.Keys)) {
        $v = $Vendor[$m]
        if (-not $ProjectPlugins.ContainsKey($v.Host)) { Warn "Engine module $m wasn't placed: the $($v.Host) mod isn't in the project."; continue }
        $hostDir = $ProjectPlugins[$v.Host]
        $hostRel = $hostDir.Substring($ProjectDir.Length + 1)
        $src = P $SourceRoot (To-Native $v.Dir)
        $dst = P $hostDir 'Source' $m
        if ((Get-BuildCsFiles $dst).Count -eq 0) {
            if (-not (Test-Path -LiteralPath $src)) { Warn "The source of engine module $m wasn't downloaded ($src). Run the script again."; continue }
            Copy-Tree $src $dst -ExcludeDirs @((P $src 'Intermediate'), (P $src 'Binaries'))
        }
        $upf = P $hostDir "$($v.Host).uplugin"
        $hd = Read-Json $upf
        $mods = New-Object System.Collections.Generic.List[object]
        $listed = $false
        foreach ($e in (As-Array (Get-Prop $hd 'Modules'))) { $mods.Add($e); if ((Get-Prop $e 'Name') -eq $m) { $listed = $true } }
        if (-not $listed) {
            $mods.Add([pscustomobject]@{ Name = $m; Type = $v.Type; LoadingPhase = 'Default' })
            Set-Prop $hd 'Modules' ([object[]]$mods.ToArray())
            Save-Json $hd $upf
        }
        Ok ("{0}: engine module {1} added (your CSS install has it only as source; copied unchanged, listed in {2}.uplugin)" -f $hostRel, $m, $v.Host)
    }

    # The OpenXR SDK module (see $SdkVendor): its headers come from the engine source and its loader from the engine's
    # download list. Both go into the OpenXR mod, and its build rules point at the mod's folder (Convert-OpenXRSdkBuildCs).
    foreach ($m in @($SdkVendor.Keys)) {
        $v = $SdkVendor[$m]
        if (-not $ProjectPlugins.ContainsKey($v.Host)) { Warn "The OpenXR SDK wasn't placed: the $($v.Host) mod isn't in the project."; continue }
        $hostDir = $ProjectPlugins[$v.Host]
        $hostRel = $hostDir.Substring($ProjectDir.Length + 1)
        $dst = P $hostDir 'Source' 'ThirdParty' $m
        if ((Get-BuildCsFiles $dst).Count -gt 0) { Note "$hostRel already has the OpenXR SDK module; left as is"; continue }
        $src = P $SourceRoot (To-Native $v.Dir)
        $bin = P $SourceRoot (To-Native $v.BinDir)
        $srcRules = P $src "$m.Build.cs"
        if (-not (Test-Path -LiteralPath $srcRules) -or -not (Test-Path -LiteralPath $bin)) { Warn "The OpenXR SDK files weren't downloaded ($src, $bin). Run the script again."; continue }
        $sdkFrom = $SourceDesc
        if (-not $UseLocal) { $sdkFrom = "$Branch commit $commit" }
        $rules = Convert-OpenXRSdkBuildCs ([System.IO.File]::ReadAllText($srcRules)) $sdkFrom
        if (-not $rules) { Warn "The OpenXR SDK's build rules ($srcRules) aren't the ones this script knows how to point at the mod, so the SDK wasn't placed. Tell Claude."; continue }
        Copy-Tree $src $dst
        Copy-Tree $bin (P $dst 'loader')
        Write-TextFile (P $dst "$m.Build.cs") $rules
        Ok ("{0}: the OpenXR SDK (headers and loader) added as module {1} in Source\ThirdParty (your CSS install leaves it out)" -f $hostRel, $m)
    }

    # Where NativeVR lives: next to ExampleMod (Mods\GameFeatures in 1.2).
    if ($ProjectPlugins.ContainsKey($ModName)) { $ModDir = $ProjectPlugins[$ModName] }
    else {
        $modParent = $ModsDir
        if ($exampleFile) { $modParent = Split-Path -Parent (Split-Path -Parent $exampleFile) }
        elseif (Test-Path -LiteralPath (P $ModsDir 'GameFeatures')) { $modParent = P $ModsDir 'GameFeatures' }
        $ModDir = P $modParent $ModName
    }
    $ModRel = $ModDir.Substring($ProjectDir.Length + 1)

    # The template's content goes into Content first so its internal references stay intact. Only asset files are copied:
    # Epic's packs also hold source art (FBX), and the editor's auto reimport (Editor Preferences > Loading & Saving)
    # offers to import such files when they appear, then re-imports the meshes made from them over Epic's.
    # -FreshTemplate (or a first run) moves the old template folders to the backup folder before copying.
    $RefreshContent = $FirstRun -or $FreshTemplate
    if ($FreshTemplate -and -not $FirstRun) { Note 'Fresh template: the template folders in Content go to _NativeVR_Backup and are copied again from the download.' }
    $AssetPatterns = @('*.uasset', '*.umap')
    $ContentMoved = New-Object System.Collections.Generic.List[string]
    $StrayArt = 0
    $MoveTargets = New-Object System.Collections.Generic.List[string]
    $AlreadyInMod = New-Object System.Collections.Generic.List[string]
    foreach ($rf in @(Get-ChildItem -LiteralPath $TemplateContent -File)) { Warn "Template file $($rf.Name) sits directly in Content and was not copied; move it by hand if the editor reports it missing." }
    $ContentTops = New-Object System.Collections.Generic.List[object]
    foreach ($top in @(Get-ChildItem -LiteralPath $TemplateContent -Directory)) { $ContentTops.Add([pscustomobject]@{ Name = $top.Name; FullName = $top.FullName }) }
    foreach ($sp in $SharedPacks) {
        $pc = P $SourceRoot (To-Native $sp.Rel) 'Content'
        if (Test-Path -LiteralPath $pc) { $ContentTops.Add([pscustomobject]@{ Name = $sp.Mount; FullName = $pc }) }
        else { Warn "The shared content pack $($sp.Mount) wasn't downloaded ($pc). Run the script again." }
    }
    foreach ($top in $ContentTops) {
        $projTop = P $ContentDir $top.Name
        $children = @(Get-ChildItem -LiteralPath $top.FullName -Directory)
        if (-not $FirstRun) {
            $inMod = Test-Path -LiteralPath (P $ModDir 'Content' $top.Name)
            if ($inMod) { $AlreadyInMod.Add($top.Name); continue }
        }
        if (Test-Path -LiteralPath $projTop) {
            if ($RefreshContent) {
                foreach ($child in @(Get-ChildItem -LiteralPath $top.FullName)) {
                    $old = P $projTop $child.Name
                    if (Test-Path -LiteralPath $old) { Backup-Item $old $ProjectDir; $ContentMoved.Add("$($top.Name)\$($child.Name)") }
                }
                if (@(Get-ChildItem -LiteralPath $projTop -Force).Count -eq 0) { Remove-Item -LiteralPath $projTop -Force }
            } else {
                # Source art an earlier version of this script copied in goes to the backup folder.
                $srcFull = $top.FullName.TrimEnd($Sep)
                foreach ($f in @(Get-FilesFast $top.FullName '*')) {
                    if ($f -match '\.(uasset|umap)$') { continue }
                    $rel = $f.Substring($srcFull.Length).TrimStart($Sep)
                    $old = P $projTop $rel
                    if (Test-Path -LiteralPath $old -PathType Leaf) { Backup-Item $old $ProjectDir; $ContentMoved.Add("$($top.Name)\$rel"); $StrayArt++ }
                }
            }
        }
        $shared = $false
        if (Test-Path -LiteralPath $projTop) {
            foreach ($pc in @(Get-ChildItem -LiteralPath $projTop)) { if (-not (Test-Path -LiteralPath (P $top.FullName $pc.Name))) { $shared = $true; break } }
        }
        Copy-Tree $top.FullName $projTop -NoOverwrite -Files $AssetPatterns
        if ($shared) { foreach ($child in $children) { $MoveTargets.Add("$($top.Name)\$($child.Name)") } }
        else { $MoveTargets.Add($top.Name) }
    }
    if ($MoveTargets.Count -gt 0) { Ok ("Template content is in Content: {0}" -f ($MoveTargets -join ', ')) }
    if ($AlreadyInMod.Count -gt 0) { Ok ("Template content already moved into {0}: {1}" -f $ModName, ($AlreadyInMod -join ', ')) }
    if ($StrayArt -gt 0) { Ok "Moved $StrayArt source art files (FBX) out of the template folders; the editor offered to import them over Epic's meshes" }
    # The editor remembers which source files it saw in Content (Intermediate\ReimportCache). With files gone it would
    # offer to delete the assets made from them, so that memory goes to the backup folder as well; at its next start the
    # editor takes a new snapshot without asking anything.
    $ReimportCacheReset = $false
    if ($ContentMoved.Count -gt 0) {
        foreach ($bin in @(Get-ChildItem -LiteralPath (P $ProjectDir 'Intermediate' 'ReimportCache') -Filter '*.bin' -File -ErrorAction SilentlyContinue)) {
            Backup-Item $bin.FullName $ProjectDir
            $ReimportCacheReset = $true
        }
        if ($ReimportCacheReset) { Ok 'Reset the editor''s auto reimport memory (it takes a new snapshot at the next start, without prompts)' }
    }

    # Template fixes for FactoryGame. The template content is in Content, or in the mod if it was moved there.
    $TplRoot = $null; $TplMount = $null
    foreach ($c in @(@((P $ContentDir 'VRTemplate'), '/Game'), @((P $ModDir 'Content' 'VRTemplate'), "/$ModName"))) {
        if (-not $TplRoot -and (Test-Path -LiteralPath $c[0])) { $TplRoot = $c[0]; $TplMount = $c[1] }
    }
    $MapFix = 'not found'
    $GridMaterialFile = $null; $GridMaterialPkg = ''
    if ($TplRoot) {
        $mapFile = P $TplRoot 'Maps' 'VRTemplateMap.umap'
        if (Test-Path -LiteralPath $mapFile) { $MapFix = Repair-TemplateMapLights $mapFile }
        $GridMaterialFile = P $TplRoot 'Materials' 'M_GridRotation.uasset'
        if (Test-Path -LiteralPath $GridMaterialFile) { $GridMaterialPkg = "$TplMount/VRTemplate/Materials/M_GridRotation" } else { $GridMaterialFile = $null }
    }
    switch ($MapFix) {
        'done' { Ok 'Template map: the campfire light, a fill light and the sky light switched from Static to Movable (FactoryGame turns baked lighting off, so Static lights never show)' }
        'already' { Ok 'Template map: its lights are already Movable' }
        'changed' { Warn 'VRTemplateMap differs from Epic''s original, so its lights were left alone. If the campfire light doesn''t show: in the map select PointLight4, PointLight5 and SkyLightPC2, set Mobility to Movable, save.' }
    }

    # The NativeVR mod: a content mod that depends on everything above.
    $newDeps = New-Object System.Collections.Generic.List[object]
    # NativeVR's own C++ mod (loads early and hands OpenXR its loader), when the project has it.
    if ($ProjectPlugins.ContainsKey('NativeVRCore') -and $ModName -ne 'NativeVRCore') { $newDeps.Add([pscustomobject]@{ Name = 'NativeVRCore'; Enabled = $true }) }
    foreach ($n in $DirectNeeds) { if ($ToFetch.Contains($n) -or $FromEngine.Contains($n)) { $newDeps.Add([pscustomobject]@{ Name = $n; Enabled = $true }) } }
    $modFile = P $ModDir "$ModName.uplugin"
    if (Test-Path -LiteralPath $modFile) {
        $nd = Read-Json $modFile
        $created = $false
    } else {
        New-Item -ItemType Directory -Path (P $ModDir 'Content') -Force | Out-Null
        if ($exampleDesc) { $nd = ((ConvertTo-UeJson $exampleDesc) | ConvertFrom-Json) }
        else { $nd = [pscustomobject]@{ FileVersion = 3; Category = 'Modding'; RequiredOnRemote = $true } }
        Set-Prop $nd 'Version' 1
        Set-Prop $nd 'VersionName' '0.1.0'
        Set-Prop $nd 'SemVersion' '0.1.0'
        Set-Prop $nd 'FriendlyName' $ModName
        Set-Prop $nd 'Description' 'Native VR for Satisfactory, built on Epic''s VR Template.'
        Set-Prop $nd 'CreatedBy' 'Thanatos'
        foreach ($u in @('CreatedByURL', 'DocsURL', 'SupportURL', 'MarketplaceURL')) { if (Get-Prop $nd $u) { Set-Prop $nd $u '' } }
        Set-Prop $nd 'CanContainContent' $true
        Remove-Prop $nd 'Modules'
        Remove-Prop $nd 'LocalizationTargets'
        if ($exampleFile) {
            $icon = P (Split-Path -Parent $exampleFile) 'Resources' 'Icon128.png'
            if (Test-Path -LiteralPath $icon) { New-Item -ItemType Directory -Path (P $ModDir 'Resources') -Force | Out-Null; Copy-Item -LiteralPath $icon -Destination (P $ModDir 'Resources' 'Icon128.png') -Force }
        }
        $created = $true
    }
    $modDeps = New-Object System.Collections.Generic.List[object]
    $depNames = New-Set
    foreach ($e in (As-Array (Get-Prop $nd 'Plugins'))) { $dn = [string](Get-Prop $e 'Name'); if ($dn -and $depNames.Add($dn)) { $modDeps.Add($e) } }
    if ($depNames.Add('SML')) { $modDeps.Add($smlDep) }
    $added = New-Object System.Collections.Generic.List[string]
    foreach ($e in $newDeps) { if ($depNames.Add($e.Name)) { $modDeps.Add($e); $added.Add($e.Name) } }
    if ($created -or $added.Count -gt 0) {
        Set-Prop $nd 'Plugins' ([object[]]$modDeps.ToArray())
        Save-Json $nd $modFile
    }
    if ($created) { Ok "$ModRel created (depends on: $((@($modDeps | ForEach-Object { $_.Name })) -join ', '))" }
    elseif ($added.Count -gt 0) { Ok "$ModRel kept; added dependencies: $($added -join ', ')" }
    else { Ok "$ModRel kept as is" }
    $NeedsDataAsset = -not (Test-Path -LiteralPath (P $ModDir 'Content' "$ModName.uasset"))

    # If FactoryGame.uproject switches off a plugin we need, switch it on (small text edit, backup kept).
    $uptext = [System.IO.File]::ReadAllText($Uproject)
    $newtext = $uptext
    foreach ($n in (@($ToFetch.Keys) + @($FromEngine.Keys))) {
        $rx = '\{[^{}]*"Name"\s*:\s*"' + [regex]::Escape($n) + '"[^{}]*\}'
        $newtext = [regex]::Replace($newtext, $rx, { param($m) [regex]::Replace($m.Value, '"Enabled"\s*:\s*false', '"Enabled": true') })
    }
    if ($newtext -ne $uptext) {
        Copy-Item -LiteralPath $Uproject -Destination (P $LogDir "FactoryGame.uproject.before-$Stamp") -Force
        [System.IO.File]::WriteAllText($Uproject, $newtext, $Utf8NoBom)
        Ok 'FactoryGame.uproject had some of these plugins switched off; switched them on (old copy kept in Saved\NativeVR-Setup)'
    }
    $InputNote = $null
    $tplInputIni = P $TemplateDir 'Config' 'DefaultInput.ini'
    $projInputIni = P $ProjectDir 'Config' 'DefaultInput.ini'
    if ((Test-Path -LiteralPath $tplInputIni) -and (Test-Path -LiteralPath $projInputIni)) {
        $InputNote = Update-InputContexts $tplInputIni $projInputIni
        if ($InputNote) { Ok $InputNote }
    }
    Save-Json ([pscustomobject]@{ FirstRun = $Stamp; ModDir = $ModRel; Source = $SourceDesc }) $StateFile

    # ------------------------------------------------------ Claude Code ---
    Step 'Setting the project up for Claude Code'
    function To-RulePath([string]$p) {
        $full = [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/')
        if ($full -match '^([A-Za-z]):[\\/](.*)$') { return '//' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2].Replace('\', '/') + '/**' }
        return '/' + $full + '/**'
    }
    $settingsFile = P $ProjectDir '.claude' 'settings.json'
    if ($FirstRun -or -not (Test-Path -LiteralPath $settingsFile)) {
        $settings = [pscustomobject]@{
            permissions = [pscustomobject]@{
                additionalDirectories = [object[]]@($EngineDir, $SourceRoot)
                deny = [object[]]@(('Edit(' + (To-RulePath $EngineDir) + ')'), ('Edit(' + (To-RulePath $SourceRoot) + ')'))
            }
        }
        Save-Json $settings $settingsFile
        Ok '.claude\settings.json: Claude Code can read the engine and source folders but is blocked from editing them'
    } else { Note '.claude\settings.json already exists; left as is' }

    $claudeFile = P $ProjectDir 'CLAUDE.md'
    if ($FirstRun -or -not (Test-Path -LiteralPath $claudeFile)) {
        $claude = @'
# NativeVR - project guide for Claude Code

NativeVR is a native VR mod for Satisfactory 1.2, built in this SML starter project by Thanatos.
Read this whole file first. Then read `Saved\NativeVR-Setup\report.md`: the latest setup run, which plugins were brought in, gaps found in the engine install, the editor steps still to do, and the last build result.

## Where things are
- Project: `{{PROJECT}}`
- CSS engine install (UE 5.6.1, Coffee Stain fork): `{{ENGINE}}` - READ ONLY
- Engine source, partial download for reference: `{{SOURCE}}` - READ ONLY. Only the folders NativeVR needs were fetched, from {{SOURCEDESC}}.
- NativeVR mod (content, a Game Feature mod): `{{MODREL}}`
- NativeVRCore mod (C++ that has to load before the engine sets up VR): `Mods\NativeVRCore`. It hands OpenXR its loader, and in the shipped game it takes XRBase's FDisplayMappingPS off the engine's global shader check.
- Epic's plugins the template needs and the CSS install lacks (OpenXR, XRBase, OpenXRHandTracking, OpenXREyeTracker, LiveLink) sit in Mods as their own mods, code unchanged. Engine modules the CSS install has only as source are copied unchanged into the mod that uses them and listed in its .uplugin (for example `LiveLinkAnimationCore` and `LiveLinkMessageBusFramework` in `Mods\LiveLink`, `AugmentedReality` in `Mods\XRBase`); the OpenXR SDK module, which the install leaves out entirely, is in `Mods\OpenXR\Source\ThirdParty\OpenXR` with its paths pointed at the mod. The report lists them.
- Epic's VR Template content stays in `Content` as the test bed: the template's folders plus its shared packs (LevelPrototyping, Weapons, VRSpectator), asset files only (no FBX). NativeVR's own assets go in the mod.
- Setup script: `Setup-NativeVR.ps1` in the project root (a copy is kept in `Saved\NativeVR-Setup`). Re-running it only adds what is missing. `-ExtraPlugins Name1,Name2` brings in more Epic plugins from source; `-FreshTemplate` replaces the template content with a clean, fixed copy; `-Fresh` starts over (old copies go to `_NativeVR_Backup`). When you run it yourself, add `-NoPause`. The fixes only the editor can make are in `Saved\NativeVR-Setup\NativeVR-EditorFixes.py` (in the editor: Output Log, Cmd, `py "<that file>"`).
- GitHub repo: https://github.com/wirelesstechsense-afk/Satisfactory-1.2-Native-VR (public). It holds only NativeVR's own files: `Mods\NativeVRCore`, `Mods\GameFeatures\NativeVR`, `Setup-NativeVR.ps1`, CLAUDE.md and README.md. Epic's plugins and the template content are never committed there (Epic's license doesn't allow posting engine source publicly); this script fetches them.
- Logs: `Saved\NativeVR-Setup\` (setup, build, report) and the editor log at `Saved\Logs\FactoryGame.log`.
- Game: Satisfactory 1.2 on Steam (game DLLs use the `FactoryGameSteam-` prefix), SML 3.12. Game log: `%LOCALAPPDATA%\FactoryGame\Saved\Logs\FactoryGame.log`.

## Ground rules from Thanatos (never break these)
1. Never modify the CSS engine install, and never rebuild the engine from source. All work lives in this project.
2. Never remove code from Epic's plugins. When something is missing, pull the missing dependency in (vendor it into a mod) instead of cutting the code that needs it. Editing a .uplugin descriptor is fine.
3. Build the editor only with:
   `& "{{BUILDBAT}}" FactoryEditor Win64 Development -Project="{{UPROJECT}}" -WaitMutex -FromMsBuild`
   Not "Build Solution" in Visual Studio. Never delete engine Binaries folders.
4. Close the editor before building C++. After every code change, build, read the log yourself, and only then say it works.
5. In 1.2, content mods are Game Feature mods: they need an `FGGameFeatureData` data asset named exactly after the mod (`{{MODNAME}}`) in the mod's content root, with Initial State set to Active.
6. Add components to the game's actors with SML Actor Mixins, not SCS hooks. Log with SML's logging, not Print String (hidden in Shipping builds).
7. C++ must use `TObjectPtr<>` for UObject members and full include paths (for example `Hologram/FGHologram.h`).
8. VR stays on Epic's own plugins. No third-party VR frameworks (VRExpansionPlugin is excluded).

## How to work with Thanatos
- He knows Unreal modding well but is new to C++. Explain every code change in plain language, without jargon.
- Explain the root cause before the fix.
- Give paste-ready PowerShell for anything he runs, and say exactly what you need from him (a log, a click in the editor, a test in the headset).
- Keep deliverables to the fewest files possible.
- On big features, propose the approach first and wait for his OK before writing large amounts of code.

## Current milestone: Epic's VR Template running in VR Preview inside FactoryGame.uproject
The setup script placed Epic's XR plugins (with hand and eye tracking and LiveLink) in Mods as their own mods, copied the engine modules they need into them, copied the template content and its shared packs into Content, fixed the template for FactoryGame (baked lights made Movable, the grid material saved for Nanite), added the template's input mapping contexts to `Config\DefaultInput.ini`, and created the NativeVR mod with its data asset. The editor steps that remain are listed in the report (normally just opening the template map and VR Preview).
If the build fails, the report's "Gaps" section lists engine modules the CSS install lacks that the script couldn't place itself; their source is already downloaded for reference. Pull them in following rule 2, explaining the plan to Thanatos first.
Next milestone: NativeVR loading in the real game with VR on (packaged with Alpakit).

## Known facts (check here before investigating again)
- OpenXR looks for openxr_loader.dll only in `Engine\Binaries\ThirdParty\OpenXR\win64`, which neither the CSS install nor the game has. NativeVRCore hands it the copy the OpenXR mod's build puts in `Mods\OpenXR\Binaries\Win64`, through IOpenXRExtensionPlugin::GetCustomLoader. Good log line: "InitInstance found and will use CustomLoader from plugin NativeVRCore".
- OpenXRInput only creates controller actions for Enhanced Input mapping contexts it knows when the XR session starts: Enhanced Input's Default Mapping Contexts (the setup script adds the template's to `Config\DefaultInput.ini`, which only affects the editor), or contexts attached through IMotionController::AttachInputMappingContexts or UOpenXRInputFunctionLibrary::BeginXRSession. In the game, NativeVR must attach its own contexts before turning VR on.
- FactoryGame defines ECC_GameTraceChannel1 as "Projectile" (blocks by default). The VR Template uses that channel as "3DWidget" for its menu laser, so in this project the template's laser can hit other objects. NativeVR's pointers must not use channel 1.
- What the September builds (the old NativeVR, before this setup) found in the shipped game. XRBase's FDisplayMappingPS isn't in the game's shader library: the game stops at startup with "Missing global shader FDisplayMappingPS" (NativeVRCore's shader fix handles it, and HDR output must stay off in VR). The modding headers have WITH_MGPU=1 but the game was built with 0, so Epic's XR plugins need WITH_MGPU=0 when built for the game. That build reached the main menu in VR through Virtual Desktop. Loading a save with VR on crashed inside the game's Sentry plugin (unsolved).
- The game ships HeadMountedDisplay, EyeTracker, the D3D11/D3D12/Vulkan/OpenGL RHIs, MRMesh, EnhancedInput and ControlRig. It doesn't ship XRBase, AugmentedReality, OpenXR or LiveLinkAnimationCore.
- The CSS install keeps some of Epic's plugins as source only, with nothing compiled (OpenXRHandTracking, OpenXREyeTracker, LiveLink), and some engine modules too (LiveLinkAnimationCore, LiveLinkMessageBusFramework). The build tools prefer a mod over an engine plugin of the same name, but the editor keeps the engine's copy when the two have the same "Version", so the mods made from these carry a higher "Version" in their .uplugin (the setup script sets it). An engine module the install lacks goes, unchanged, into the mod that uses it, listed in that mod's .uplugin.
- The VR Template's B_AssetGuideline (Asset User Data on the VRPawn camera) asks for OpenXR, OpenXREyeTracker and OpenXRHandTracking. When those mods are missing the editor shows "Missing Plugins": Dismiss it. Enable Missing switches on the engine's uncompiled copies and the editor won't start; Remove Guideline edits the template's VRPawn.
- Git (sparse download) deletes downloaded folders outside its folder list that hold only ignored files whenever the list changes; the engine's .gitignore ignores all the art. The setup script adds every folder to the list before downloading into it.
- The game ships neither LiveLink nor Takes. LiveLink's .uplugin depends on Takes and ContentBrowserAssetDataSource (editor tools), so before packaging hand tracking for the game, check that the game build accepts it (those two dependencies may need "TargetAllowList": ["Editor"]).
- Teleport in the template map probably finds no valid spot: FactoryGame's navigation settings build the navmesh only around navigation invokers (the creatures) and only after the game releases its initial build lock. NativeVR's own movement won't rely on the template's navmesh teleport.
- The editor splash is `Content\Splash\EdSplash.png`. Regenerating Content with the asset generator drops it; the starter project's original is in `Content_PreGenerate\Splash`.
- FactoryGame turns baked lighting off (`r.AllowStaticLighting=False`): lights set to Static never show and baked lightmaps are ignored. The template map baked its campfire light (PointLight4), a fill light (PointLight5) and the sky light, so the setup script switches those to Movable. NativeVR's own lights must be Movable (or Stationary).
- Don't put source art (FBX and the like) into Content next to assets; the splash PNGs in `Content\Splash` are the one deliberate exception. With this project's Auto Reimport settings (Editor Preferences > Loading & Saving) the editor offers to import new source files and re-imports the assets made from them; that once replaced nine LevelPrototyping meshes with damaged copies. If that prompt appears for template folders, click Don't Import. The editor remembers the source files it has seen in `Intermediate\ReimportCache`; with the editor closed, deleting that file makes it take a fresh snapshot without prompts.
- The template's purple cubes and ball are Epic's design: they use `MI_VRColorway` (base colour 0.30, 0.06, 1.0).
- The template map already sets VRGameMode as its GameMode Override.
- LevelPrototyping's meshes use Nanite (FactoryGame has Nanite on and deferred shading; the template was made for forward shading without Nanite). Materials on them need "Used with Nanite"; of the template's own, only M_GridRotation lacked it, and the setup script saves it with the flag.
- NativeVR's data asset `/NativeVR/NativeVR` (FGGameFeatureData) starts empty. When NativeVR adds user settings, narrative messages, an icon library or child input mapping contexts, add matching "Primary Asset Types to Scan" entries to it (ExampleMod's data asset shows the pattern: FGUserSetting, FGMessage, FGIconLibrary, FGChildInputMappingContext).
- Normal noise in this project's editor log, not caused by NativeVR: FactoryGame/SML "StructProperty ... is not initialized properly" errors, Wwise "Current platform Windows not found" (no generated soundbanks), "Short type name" warnings, and OpenXR's warnings that the template's input actions have empty descriptions.

## The vision (the bar: Half-Life: Alyx, Skyrim VR with VRIK and HIGGS, the Titanfall 2 VR mod, Into the Radius 2, Bonelab)
1. Native-feeling VR: menus work in both eyes, switch between VR and flat from settings at any time, and options for common VR rendering fixes in SML's Mods menu (main menu and in game).
2. Full body (VRIK-style): very smooth animation, ALS-style movement blending, real and motion-driven leaning that look great to other players in multiplayer.
3. Hands (HIGGS-style): physical grabbing, Alyx-style gravity pull of items to the hand, highlights on anything that can be grabbed or used.
4. Body inventory: a tool belt to take tools from, and a bag you drop items into over your shoulder to put them in the inventory.
5. Vehicles: physical driving controls, and interior buttons and controls pressed by hand wherever possible.
6. Everything Dortamur's UEVR Enhancements mod does, without needing UEVR.
7. Later: an iPad companion screen with factory stats and touch controls.
Target PC: a minimum-spec VR laptop (i7-10750H, RTX 2060 mobile, 16 GB RAM). Keep CPU cost low, especially per-player costs in multiplayer.
'@
        $claude = $claude.Replace('{{PROJECT}}', $ProjectDir).Replace('{{ENGINE}}', $EngineDir).Replace('{{SOURCE}}', $SourceRoot).Replace('{{SOURCEDESC}}', $SourceDesc)
        $claude = $claude.Replace('{{MODREL}}', $ModRel).Replace('{{MODNAME}}', $ModName).Replace('{{BUILDBAT}}', $BuildBat).Replace('{{UPROJECT}}', $Uproject)
        Write-TextFile $claudeFile ($claude -replace "`r?`n", "`r`n")
        Ok 'CLAUDE.md: your rules, the plan and the vision, read by Claude Code at the start of every session'
    } else { Note 'CLAUDE.md already exists; left as is' }

    $LaterSteps = New-Object System.Collections.Generic.List[string]
    if ($MoveTargets.Count -gt 0) {
        $LaterSteps.Add(("Epic's template content stays in Content ({0}) as NativeVR's test bed. NativeVR's own assets go in {1}'s Content folder. If template folders ever get moved into {1}, run this script again so Config\DefaultInput.ini follows them." -f ($MoveTargets -join ', '), $ModName))
    }

    # ------------------------------------------------------------ build ---
    $BuildResult = 'skipped'
    $BuildLog = P $LogDir "build-$Stamp.log"
    $ErrorLines = @()
    if (-not $SkipBuild -and $OnWindows) {
        Step 'Building the editor (FactoryEditor). The first build of new plugins takes a while...'
        $buildLines = New-Object System.Collections.Generic.List[string]
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & $BuildBat 'FactoryEditor' 'Win64' 'Development' "-Project=$Uproject" '-WaitMutex' '-FromMsBuild' 2>&1 | ForEach-Object { $line = "$_"; $buildLines.Add($line); Write-Host "    $line" }
        } finally { $ErrorActionPreference = $old }
        $code = $LASTEXITCODE
        Write-TextFile $BuildLog ($buildLines -join "`r`n")
        $ErrorLines = @($buildLines | Where-Object { $_ -match '(: error |error :|^ERROR:|Unable to|Could not find|does not list)' } | Select-Object -First 25)
        if ($code -eq 0) { $BuildResult = 'succeeded'; Ok 'Build succeeded' }
        else { $BuildResult = "failed (exit $code)"; Warn "Build failed. The first errors are below and in $BuildLog" }
    } elseif ($SkipBuild) { Note 'Build skipped (-SkipBuild)' }

    # ----------------------------------------------------- editor fixes ---
    # Two fixes only the editor can make (see $EditorFixesPy): the template's grid material saved with "Used with
    # Nanite", and NativeVR's data asset. The editor runs once without a window; anything it couldn't do becomes an
    # editor step that runs the same script by hand.
    $PyFile = P $LogDir 'NativeVR-EditorFixes.py'
    $PyResultFile = P $LogDir 'editor-fixes-result.json'
    $EditorFixLog = P $LogDir "editor-fixes-$Stamp.log"
    $py = $EditorFixesPy.Replace('{{MODNAME}}', $ModName).Replace('{{GRIDMATERIAL}}', $GridMaterialPkg).Replace('{{RESULTFILE}}', $PyResultFile.Replace('\', '/'))
    $py = $py.Replace('{{DATAASSETFILE}}', (P $ModDir 'Content' "$ModName.uasset").Replace('\', '/'))
    Write-TextFile $PyFile ($py -replace "`r?`n", "`r`n")
    $NaniteFixNeeded = ($GridMaterialFile -and -not (Test-FileHasText $GridMaterialFile 'bUsedWithNanite'))
    $EditorFixNote = $null
    if ($NeedsDataAsset -or $NaniteFixNeeded) {
        if ($BuildResult -like 'failed*') { $EditorFixNote = 'not run, because the build failed' }
        elseif (-not $hasPython) { $EditorFixNote = 'not run, because the engine has no Python editor scripting' }
        else {
            Step 'Applying the fixes only the editor can make (the editor runs without a window; a few minutes)'
            $fixRes = Invoke-EditorFixes $PyFile $PyResultFile $EditorFixLog
            if ($fixRes -is [string]) {
                $EditorFixNote = $fixRes
                Warn "The editor fixes didn't run: $fixRes. The editor steps below include running them by hand."
            } else {
                $EditorFixNote = "ran (log: $EditorFixLog)"
                foreach ($k in @($fixRes.Keys)) { Note ("{0}: {1}" -f $k, $fixRes[$k]) }
            }
        }
        $NeedsDataAsset = -not (Test-Path -LiteralPath (P $ModDir 'Content' "$ModName.uasset"))
        $NaniteFixNeeded = ($GridMaterialFile -and -not (Test-FileHasText $GridMaterialFile 'bUsedWithNanite'))
        if (-not $NaniteFixNeeded) { Ok 'Template grid material (M_GridRotation) is saved with "Used with Nanite"' }
        if (-not $NeedsDataAsset) { Ok ("{0}\Content\{1}.uasset: the mod's data asset (FGGameFeatureData)" -f $ModRel, $ModName) }
    }

    # Editor steps still to do (also written to the report).
    $EditorSteps = New-Object System.Collections.Generic.List[string]
    $EditorSteps.Add('Open FactoryGame.uproject.')
    $byHand = @()
    if ($NeedsDataAsset) { $byHand += ("creates the {0} data asset (FGGameFeatureData; every 1.2 content mod needs one, or the editor logs ""GameFeatureData is missing"")" -f $ModName) }
    if ($NaniteFixNeeded) { $byHand += 'saves the template''s grid material with "Used with Nanite" (ends the Map Check warning about M_GridRotation)' }
    if ($byHand.Count -gt 0) {
        $restart = ''
        if ($NeedsDataAsset) { $restart = ' Then restart the editor.' }
        $EditorSteps.Add(("Once only: Window > Output Log, set the box at the bottom left to Cmd, paste  py ""{0}""  and press Enter. It {1}.{2}" -f $PyFile, ($byHand -join ' and '), $restart))
    }
    if ($TrackingSkipped) { $EditorSteps.Add('If a "Missing Plugins" prompt appears for OpenXRHandTracking or OpenXREyeTracker, click Dismiss. Never Enable Missing: it switches on the engine''s uncompiled copies and the editor won''t start.') }
    $EditorSteps.Add('Open the template map: Content > VRTemplate > Maps > VRTemplateMap (it already uses VRGameMode).')
    $EditorSteps.Add('Start your headset''s PC link so an OpenXR runtime is running (Virtual Desktop with VDXR, SteamVR or Quest Link), then Play > VR Preview.')

    # ----------------------------------------------------------- report ---
    $report = New-Object System.Collections.Generic.List[string]
    $report.Add("# NativeVR setup report ($Stamp)")
    $report.Add('')
    $report.Add("- Source: $SourceDesc")
    $report.Add("- Engine: $EngineDir")
    $report.Add("- Python editor scripting in the engine: $(if ($hasPython) { 'yes' } else { 'no' })")
    $report.Add("- Mod: $ModRel")
    $buildNote = ''
    if ($BuildResult -ne 'skipped') { $buildNote = " (log: $BuildLog)" }
    $report.Add("- Build: $BuildResult$buildNote")
    if ($S.BackupRoot) { $report.Add("- Old copies moved to: $($S.BackupRoot)") }
    $report.Add('')
    $report.Add('## Plugins')
    foreach ($k in $ToFetch.Keys) { $report.Add("- Mods\$k - Epic's $k plugin from the engine source, code unchanged; its .uplugin got SML fields, EnabledByDefault, RequiredOnRemote=false. ($(if ($Need.Contains($k)) { $Need[$k] } else { 'needed by another plugin' }))") }
    foreach ($k in $FromEngine.Keys) { $report.Add("- $k - already in the engine install; NativeVR depends on it. ($($FromEngine[$k]))") }
    foreach ($k in $Skipped.Keys) { $report.Add("- $k - skipped: $($Skipped[$k])") }
    $report.Add('')
    $report.Add('## Gaps in the CSS install')
    foreach ($l in $gapLines) { $report.Add($l) }
    $report.Add('')
    $report.Add('## Template content, fixes and input')
    if ($SharedPacks.Count -gt 0) { $report.Add(('- Shared content packs the template uses, copied to Content: {0}' -f (@($SharedPacks | ForEach-Object { "$($_.Mount) ($($_.Rel))" }) -join ', '))) }
    else { $report.Add('- The template lists no shared content packs.') }
    $report.Add('- Only asset files (.uasset, .umap) are copied; the packs'' source art (FBX) stays in the download cache.')
    if ($RefreshContent -and $ContentMoved.Count -gt 0) { $report.Add("- Fresh copy: the old template folders were moved to the backup folder ($($ContentMoved -join ', ')).") }
    if ($StrayArt -gt 0) { $report.Add("- $StrayArt source art files (FBX) from an earlier run were moved to the backup folder.") }
    if ($ReimportCacheReset) { $report.Add('- The editor''s auto reimport memory (Intermediate\ReimportCache) was reset, so the editor doesn''t offer to import or delete anything for the files that left Content.') }
    $mapLine = @{ 'done' = 'switched from Static to Movable by this run'; 'already' = 'already Movable'; 'changed' = 'left alone: the map differs from Epic''s original (set PointLight4, PointLight5 and SkyLightPC2 to Movable by hand if the campfire light doesn''t show)'; 'not found' = 'map not found' }
    $report.Add("- Template map lights (campfire PointLight4, fill PointLight5, SkyLightPC2): $($mapLine[$MapFix]). FactoryGame turns baked lighting off (r.AllowStaticLighting=False), so Static lights never show.")
    if ($GridMaterialFile) { $report.Add("- Grid material M_GridRotation, Used with Nanite: $(if ($NaniteFixNeeded) { 'still to do (editor step below)' } else { 'saved' }).") }
    $report.Add("- $ModName data asset (FGGameFeatureData): $(if ($NeedsDataAsset) { 'still to do (editor step below)' } else { 'present' }).")
    if ($EditorFixNote) { $report.Add("- Editor fixes run without a window: $EditorFixNote. Script: $PyFile") }
    if ($InputNote) { $report.Add("- $InputNote") }
    $report.Add('')
    $report.Add('## Editor steps still to do')
    $sn = 0
    foreach ($st in $EditorSteps) { $sn++; $report.Add("$sn. $st") }
    if ($LaterSteps.Count -gt 0) {
        $report.Add('')
        $report.Add('## Later')
        foreach ($st in $LaterSteps) { $report.Add("- $st") }
    }
    if ($ErrorLines.Count -gt 0) {
        $report.Add('')
        $report.Add('## First build errors')
        $report.Add('```')
        foreach ($l in $ErrorLines) { $report.Add($l) }
        $report.Add('```')
    }
    if ($S.Warnings.Count -gt 0) {
        $report.Add('')
        $report.Add('## Warnings')
        foreach ($w in $S.Warnings) { $report.Add("- $w") }
    }
    Write-TextFile (P $LogDir 'report.md') ($report -join "`r`n")

    Step 'Done'
    if ($ErrorLines.Count -gt 0) { Say ''; foreach ($l in $ErrorLines) { Write-Host "    $l" -ForegroundColor Yellow } }
    Say ''
    Say "Report: $(P $LogDir 'report.md')"
    Say ''
    if ($BuildResult -like 'failed*') {
        Say 'The build failed. Send Claude the report (Saved\NativeVR-Setup\report.md), or start Claude Code in this folder and say:'
        Say '  "Read CLAUDE.md and the setup report, then get the build working."'
    } else {
        Say 'Next, in the editor:'
        $sn = 0
        foreach ($st in $EditorSteps) { $sn++; Say "  $sn. $st" }
    }
    Say ''
    Say "Claude Code: open PowerShell in $ProjectDir and run:  claude"
    Say '(The first time, accept the trust prompt so it can read the engine folders.)'
    try { Stop-Transcript | Out-Null } catch { }
    Wait-BeforeClose
    return 0
}
catch {
    Write-Host ''
    Write-Host "STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { Write-Host "  (script line $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor DarkGray }
    if ($LogDir) { Write-Host "Full log: $LogDir" }
    Write-Host 'Nothing was deleted. Fix the problem above (or paste this message to Claude) and run the script again.'
    try { Stop-Transcript | Out-Null } catch { }
    Wait-BeforeClose
    return 1
}

} $args)

$NativeVRExitCode = 0
if ($NativeVRResult.Count -gt 0 -and $NativeVRResult[-1] -is [int]) { $NativeVRExitCode = $NativeVRResult[-1] }
if ($PSCommandPath) { exit $NativeVRExitCode }

