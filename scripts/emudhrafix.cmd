@echo off
setlocal DisableDelayedExpansion
set "EMUDHRA_SELF=%~f0"
set "EMUDHRA_MODE=%~1"
set "EMUDHRA_BADARGS="
if not "%~2"=="" set "EMUDHRA_BADARGS=1"
powershell.exe -NoLogo -NoProfile -Command "$raw=[IO.File]::ReadAllText($env:EMUDHRA_SELF,[Text.Encoding]::UTF8); & ([scriptblock]::Create(($raw -split '(?m)^# POWERSHELL_BODY\r?$',2)[1]))"
exit /b %errorlevel%
# POWERSHELL_BODY
# This code is embedded in a single CMD file; it uses built-in Windows PowerShell 5.1 with no Python dependency.
$ErrorActionPreference = 'Stop'
# Does not set Console.OutputEncoding and does not call chcp; switching the legacy console code page may recreate the display buffer.
# Write-Host uses the Unicode console API; the script source is read explicitly as UTF-8 by the CMD entry point.
$script:errors = 0
$script:pending = 0
$script:updated = 0
$script:check_only = $env:EMUDHRA_MODE -eq '--check'
$script:project_dir = (Get-Location).Path
$script:python_list = @()
$script:skipped = 0
$script:reported = 0
$script:active_update = $false
$script:update_log = New-Object 'System.Collections.Generic.List[string]'

function displayText([string]$text, [string]$indent = '    ') {
    # Only text is displayed, so ANSI clear-screen/cursor-control sequences from subcommands cannot disturb existing output; the raw text is saved to a log instead.
    $text = [regex]::Replace($text, '\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)', '')
    $text = [regex]::Replace($text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
    $text = $text -replace '\r\n', "`n" -replace '\r', "`n"
    $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    foreach ($line in ($text -split "`n")) { [Console]::Error.WriteLine($indent + $line) }
}
function reportSkip([string]$label, [string]$reason) {
    $script:reported++
    if ($script:check_only) {
        Write-Host "    Skipped [$label]: $reason"
        $script:skipped++
    }
}

function findTool([string]$name) {
    # Prefer .exe/.cmd/.bat so npm.ps1 is not affected by the execution policy.
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}
function fail([string]$label, [string]$message) {
    $indent = if ($script:active_update) { '  ' } else { '' }
    displayText "Error [$label]: $message" $indent
    if ($script:update_log.Count -gt 0) {
        $full_log = $script:update_log -join "`r`n"
        displayText 'Command log (stdout and stderr, not truncated):' '    '
        displayText $full_log '      '
        try {
            $log_path = Join-Path ([IO.Path]::GetTempPath()) ('emudhra-error-' + [guid]::NewGuid().ToString('N') + '.log')
            [IO.File]::WriteAllText($log_path, $full_log, (New-Object Text.UTF8Encoding($false)))
            displayText "Full log: $log_path" '    '
        } catch { displayText "Failed to write the log file: $($_.Exception.Message)" '    ' }
    }
    $script:update_log.Clear()
    $script:active_update = $false
    $script:reported++
    $script:errors++
}
function query([string]$name, [string[]]$arguments = @()) {
    $executable = findTool $name
    if (-not $executable) { return @{ Code = 127; Text = "Command [$name] was not found." } }
    $previous = $ErrorActionPreference
    $lines = New-Object 'System.Collections.Generic.List[string]'
    try {
        $ErrorActionPreference = 'Continue'
        & $executable @arguments 2>&1 | ForEach-Object { $lines.Add($_.ToString()) }
        $code = $LASTEXITCODE
        return @{ Code = $code; Text = ($lines -join "`n") }
    } catch {
        $lines.Add($_.Exception.ToString())
        return @{ Code = 1; Text = ($lines -join "`n") }
    }
    finally { $ErrorActionPreference = $previous }
}
function updateQuery([string]$name, [string[]]$arguments = @()) {
    $result = query $name $arguments
    $script:update_log.Add("Command: $name $($arguments -join ' ')`r`nExit code: $($result.Code)`r`n$($result.Text)")
    return $result
}
function runNative([string]$name, [string[]]$arguments = @()) {
    $result = updateQuery $name $arguments
    if ($result.Code -ne 0) { throw "[$name] exited with code $($result.Code); see the command log below for the full output." }
}
function readNative([string]$name, [string[]]$arguments = @()) {
    $result = query $name $arguments
    if ($result.Code -ne 0) { throw "[$name]: $($result.Text)" }
    return $result.Text
}
function versionGe([string]$current, [string]$minimum) {
    # rc/beta/dev are not treated as final fixed versions; numeric segments are compared in order to avoid string-comparison pitfalls.
    if ($current -notmatch '^\d+(\.\d+)*(\+[A-Za-z0-9.-]+)?$') { return $false }
    $left = ($current -split '\+')[0] -split '\.'
    $right = $minimum -split '\.'
    for ($i = 0; $i -lt [Math]::Max($left.Length, $right.Length); $i++) {
        $a = if ($i -lt $left.Length) { [long]$left[$i] } else { 0 }
        $b = if ($i -lt $right.Length) { [long]$right[$i] } else { 0 }
        if ($a -gt $b) { return $true }
        if ($a -lt $b) { return $false }
    }
    return $true
}
function versionOf([string]$text) {
    if ($text -match '(?m)^[^\d]*(\d+(?:\.\d+)*(?:[-+][A-Za-z0-9._-]+)?)') { return $Matches[1] }
    throw "Could not parse version: $text"
}
function targetFor([string]$kind, [string]$version) {
    $major = ($version -split '\.')[0]
    switch ($kind) {
        go { if ($version -like '1.26.*') { return '1.26.10' }; return '1.27.3' }
        node { switch ($major) { 22 { return '22.23.4' }; 24 { return '24.22.1' }; default { return '26.12.1' } } }
        electron { switch ($major) { 42 { return '42.11.16' }; 43 { return '43.8.1' }; default { return '44.9.1' } } }
        composer { if ($version -like '1.4.*') { return '1.4.16' }; return '1.6.0' }
    }
}
function beginUpdate([string]$label, [string]$current, [string]$minimum) {
    $script:reported++
    if ($script:check_only) {
        Write-Host "Pending upgrade [$label]: [$current] → at least [$minimum]"
        $script:pending++
        return $false
    }
    $script:active_update = $true
    $script:update_log.Clear()
    Write-Host "Found [$label], current [$current], upgrading to at least [$minimum]..."
    return $true
}
function ensureVersion([string]$label, [string]$minimum, [scriptblock]$getter, [scriptblock]$updater) {
    $started = $false
    try {
        $current = & $getter
        if ([string]::IsNullOrWhiteSpace($current)) { throw 'Could not read the installed version.' }
        if (versionGe $current $minimum) { reportSkip $label "Version [$current] already satisfies [$minimum]."; return }
        if (-not (beginUpdate $label $current $minimum)) { return }
        $started = $true
        & $updater
        $after = & $getter
        if (-not (versionGe $after $minimum)) { throw "Still [$after] after the upgrade? Check sources, dependency constraints, and PATH." }
        Write-Host "  Done [$after]"
        $script:active_update = $false
        $script:update_log.Clear()
        $script:updated++
    } catch {
        fail $label $_.Exception.Message
    }
}
function invokeCheck([string]$name) {
    $before = $script:reported
    $script:active_update = $false
    $script:update_log.Clear()
    try { & $name } catch { fail $name $_.Exception.Message }
    if ($script:reported -eq $before) {
        $entry = $script:skip_reasons[$name]
        reportSkip $entry[0] $entry[1]
    }
}

# WinGet must already have an installation record for this product; only upgrade is run, never install.
# Scoop/Chocolatey are matched by the actual executable path so a second copy is not installed blindly.
function upgradeOwned([string]$tool, [string]$winget_id, [string]$scoop_name, [string]$choco_name) {
    $path = findTool $tool
    if (-not $path) { throw "Tool [$tool] was not found." }
    if ((findTool scoop) -and $path -match '(?i)[\\/]scoop[\\/]') {
        runNative scoop @('update', $scoop_name)
        return
    }
    if ((findTool choco) -and $env:ChocolateyInstall -and $path.StartsWith($env:ChocolateyInstall, [StringComparison]::OrdinalIgnoreCase)) {
        runNative choco @('upgrade', $choco_name, '-y')
        return
    }
    if ($winget_id -and (findTool winget)) {
        $listed = query winget @('list', '--id', $winget_id, '--exact', '--disable-interactivity')
        if ($listed.Code -eq 0 -and $listed.Text.Contains($winget_id)) {
            runNative winget @('upgrade', '--id', $winget_id, '--exact', '--disable-interactivity')
            return
        }
    }
    throw "Could not determine the original installation manager for [$tool]; upgrade it the original way, then run this script to verify."
}
function getGo { return (versionOf (readNative go @('version'))) }
function upgradeGo { upgradeOwned go 'GoLang.Go' go golang }
function checkGo {
    if (findTool go) { ensureVersion Go (targetFor go (getGo)) { getGo } { upgradeGo } }
}
function getNode { return (readNative node @('--version')).TrimStart('v') }
function upgradeNode {
    $target = targetFor node (getNode)
    $path = findTool node
    if ($env:NVM_SYMLINK -and $path.StartsWith($env:NVM_SYMLINK, [StringComparison]::OrdinalIgnoreCase) -and (findTool nvm)) {
        runNative nvm @('install', $target)
        runNative nvm @('use', $target)
    } elseif ($env:VOLTA_HOME -and $path.StartsWith($env:VOLTA_HOME, [StringComparison]::OrdinalIgnoreCase) -and (findTool volta)) {
        runNative volta @('install', "node@$target")
    } else {
        # Looks for LTS or regular Node via WinGet installation records; nothing may be installed from scratch on failure.
        if (findTool winget) {
            foreach ($id in @('OpenJS.NodeJS.LTS', 'OpenJS.NodeJS')) {
                $listed = query winget @('list', '--id', $id, '--exact', '--disable-interactivity')
                if ($listed.Code -eq 0 -and $listed.Text.Contains($id)) {
                    runNative winget @('upgrade', '--id', $id, '--exact', '--disable-interactivity')
                    return
                }
            }
        }
        upgradeOwned node '' nodejs nodejs-lts
    }
}
function checkNode {
    if (findTool node) { ensureVersion Node.js (targetFor node (getNode)) { getNode } { upgradeNode } }
}
function collectPython {
    $candidates = @('python3', 'python', 'pypy3', (Join-Path $script:project_dir '.venv\Scripts\python.exe'))
    if ($env:VIRTUAL_ENV) { $candidates += Join-Path $env:VIRTUAL_ENV 'Scripts\python.exe' }
    # Interpreters registered by py are system-wide; virtual environments of other projects are not walked.
    if (findTool py) {
        $registered = query py @('-0p')
        if ($registered.Code -eq 0) {
            foreach ($line in ($registered.Text -split '\r?\n')) {
                if ($line -match '([A-Za-z]:\\.+?python(?:[0-9.]*)?\.exe)\s*$') { $candidates += $Matches[1] }
            }
        }
    }
    foreach ($launcher in @('pip', 'pip3')) {
        if (findTool $launcher) {
            $debug = query $launcher @('debug', '--verbose')
            if ($debug.Text -match '(?m)^sys\.executable:\s*(.+?)\r?$') { $candidates += $Matches[1] }
        }
    }
    foreach ($candidate in $candidates) {
        if (-not (findTool $candidate)) { continue }
        # Exclude Windows app execution aliases so the Microsoft Store is not opened.
        if ((findTool $candidate) -match '\\WindowsApps\\') { continue }
        $result = query $candidate @('-c', 'import sys; print(sys.executable)')
        if ($result.Code -eq 0 -and $result.Text -and $script:python_list -notcontains $result.Text) {
            $script:python_list += $result.Text
        }
    }
}
function getPythonPackage([string]$py, [string]$package) {
    return readNative $py @('-c', "import $package; print($package.__version__)")
}
function upgradePythonPackage([string]$py, [string]$package, [string]$minimum) {
    $prefix = readNative $py @('-c', 'import sys; print(sys.prefix)')
    if ((Test-Path -LiteralPath (Join-Path $prefix 'conda-meta')) -and (findTool conda)) {
        runNative conda @('install', '-y', '-p', $prefix, "$package>=$minimum")
    } else { runNative $py @('-m', 'pip', 'install', '--upgrade', "$package>=$minimum") }
}
function checkPythonPackage([string]$package, [string]$minimum) {
    foreach ($py in $script:python_list) {
        $probe = query $py @('-c', "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('$package') else 1)")
        if ($probe.Code -ne 0) { reportSkip "$package ($py)" 'No importable module was found; no update was performed.'; continue }
        ensureVersion "$package ($py)" $minimum { getPythonPackage $py $package } { upgradePythonPackage $py $package $minimum }
    }
}
function checkPip { checkPythonPackage pip '26.2.2' }
function checkCertifi { checkPythonPackage certifi '2026.10.19' }

# Python runtimes are verified against upstream branch thresholds; the interpreter list comes from collectPython, with no separate scope.
function pythonTarget([string]$branch) {
    switch ($branch) {
        '3.13' { return '3.13.17' }
        '3.14' { return '3.14.9' }
        '3.15' { return '3.15.1' }
        default { throw "No fixed version is listed for branch [$branch]; use a supported branch or upgrade the original way." }
    }
}
function getPythonRuntime([string]$py) {
    return (readNative $py @('-c', "import sys; v=sys.version_info; print('%d.%d.%d' % v[:3] if v.releaselevel=='final' else '%d.%d.%d%s%d' % (v.major,v.minor,v.micro,v.releaselevel,v.serial))")).Trim()
}
function upgradePythonRuntime([string]$py, [string]$target) {
    $prefix = (readNative $py @('-c', 'import sys; print(sys.prefix)')).Trim()
    # Conda environments are managed by conda; do not bypass it by switching interpreters with pip.
    if ((Test-Path -LiteralPath (Join-Path $prefix 'conda-meta')) -and (findTool conda)) {
        runNative conda @('update', '--prefix', $prefix, '--yes', 'python'); return
    }
    $path = (readNative $py @('-c', "import sys; print(getattr(sys, '_base_executable', sys.executable))")).Trim()
    # Standalone uv install: upgrade the patch release on the same branch; do not install a second copy.
    if (findTool uv) {
        $uvDir = query uv @('python', 'dir')
        if ($uvDir.Code -eq 0 -and $uvDir.Text.Trim()) {
            $dir = $uvDir.Text.Trim()
            if ($path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) {
                $request = $target.Substring(0, $target.LastIndexOf('.'))
                runNative uv @('python', 'upgrade', $request); return
            }
        }
    }
    # python.org installs are upgraded through WinGet's existing product record; do not install a second copy.
    if (findTool winget) {
        $branch = $target.Substring(0, $target.LastIndexOf('.'))
        $id = "Python.Python.$branch"
        $listed = query winget @('list', '--id', $id, '--exact', '--disable-interactivity')
        if ($listed.Code -eq 0 -and $listed.Text.Contains($id)) {
            runNative winget @('upgrade', '--id', $id, '--exact', '--disable-interactivity'); return
        }
    }
    upgradeOwned $py '' python python3
}
function checkPythonRuntime {
    $seen = @{}
    foreach ($py in $script:python_list) {
        # The same interpreter may have several entry points (PATH alias, venv); check it only once by base executable.
        $real = $py
        $probe = query $py @('-c', "import os,sys; print(os.path.realpath(getattr(sys, '_base_executable', sys.executable)))")
        if ($probe.Code -eq 0 -and $probe.Text.Trim()) { $real = $probe.Text.Trim() }
        if ($seen.ContainsKey($real)) { continue }
        $seen[$real] = $true
        try {
            $current = getPythonRuntime $py
            if ($current -notmatch '^\d+\.\d+\.\d+$') { throw "Pre-release or abnormal version [$current] is not accepted as proof of a fix." }
            $branch = $current.Substring(0, $current.LastIndexOf('.'))
            $minimum = pythonTarget $branch
        } catch {
            fail "Python ($py)" $_.Exception.Message
            continue
        }
        ensureVersion "Python ($py)" $minimum { getPythonRuntime $py } { upgradePythonRuntime $py $minimum }
    }
}
function getUv { return versionOf (readNative uv @('--version')) }
function upgradeUv {
    $path = findTool uv
    foreach ($py in $script:python_list) {
        $dir = query $py @('-c', "import sysconfig; print(sysconfig.get_path('scripts'))")
        if ($dir.Code -eq 0 -and $path -eq (Join-Path $dir.Text 'uv.exe')) {
            $probe = query $py @('-c', 'import uv')
            if ($probe.Code -eq 0) { upgradePythonPackage $py uv '0.13.5'; return }
        }
    }
    $self = updateQuery uv @('self', 'update')
    if ($self.Code -eq 0) { return }
    try { upgradeOwned uv 'astral-sh.uv' uv uv }
    catch { throw "Both the self-update and the original-manager update failed: $($_.Exception.Message)" }
}
function checkUv { if (findTool uv) { ensureVersion uv '0.13.5' { getUv } { upgradeUv } } }
function getRustup { return versionOf (readNative rustup @('--version')) }
function upgradeRustup {
    $self = updateQuery rustup @('self', 'update')
    if ($self.Code -ne 0) { upgradeOwned rustup 'Rustlang.Rustup' rustup rustup.install }
}
function checkRustup { if (findTool rustup) { ensureVersion Rustup '1.29.2' { getRustup } { upgradeRustup } } }

function cargoVersions([string]$package) {
    if (-not (Test-Path -LiteralPath 'Cargo.lock')) { return }
    $raw = Get-Content -LiteralPath 'Cargo.lock' -Raw -Encoding UTF8
    foreach ($block in ($raw -split '(?m)^\[\[package\]\]')) {
        if ($block -match '(?m)^name\s*=\s*"([^"]+)"' -and $Matches[1] -eq $package) {
            if ($block -match '(?m)^version\s*=\s*"([^"]+)"') { $Matches[1] }
        }
    }
}
function checkCargoPackage([string]$package, [string]$minimum) {
    $versions = @(cargoVersions $package | Select-Object -Unique)
    foreach ($current in $versions) {
        if (versionGe $current $minimum) { reportSkip "$package/Cargo.lock" "Version [$current] already satisfies [$minimum]."; continue }
        if (@(cargoVersions $package) -notcontains $current) { continue }
        if (-not (beginUpdate "$package/Cargo.lock" $current $minimum)) { continue }
        try {
            runNative cargo @('update', '-p', "$package@$current", '--precise', $minimum)
            if (@(cargoVersions $package) -contains $current) { throw "The lockfile still contains the old branch [$current]." }
            Write-Host "  Done [$minimum (lockfile)]"
            $script:active_update = $false
            $script:update_log.Clear()
            $script:updated++
        } catch { fail $package $_.Exception.Message }
    }
}
function checkRustlsWebpki { checkCargoPackage rustls-webpki '0.103.16' }
function checkWebpkiRoots { checkCargoPackage webpki-roots '1.0.10' }
function checkWebpkiRootCerts { checkCargoPackage webpki-root-certs '1.0.10' }
function getElectron([string]$dir) { return (Get-Content -LiteralPath (Join-Path $dir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version }
function upgradeElectron([string]$scope) {
    if ($scope -eq 'global') { runNative npm @('update', '-g', 'electron') }
    elseif (Test-Path -LiteralPath 'pnpm-lock.yaml') { runNative pnpm @('update', 'electron') }
    elseif (Test-Path -LiteralPath 'yarn.lock') {
        $version = readNative yarn @('--version')
        if ($version -like '1.*') { runNative yarn @('upgrade', 'electron') }
        else { runNative yarn @('up', 'electron') }
    } else { runNative npm @('update', 'electron') }
}
function checkElectron {
    $dir = Join-Path $script:project_dir 'node_modules\electron'
    if (Test-Path -LiteralPath (Join-Path $dir 'package.json')) {
        ensureVersion Electron (targetFor electron (getElectron $dir)) { getElectron $dir } { upgradeElectron local }
    }
    if (findTool npm) {
        $result = query npm @('root', '-g')
        if ($result.Code -eq 0 -and $result.Text) {
            $dir = Join-Path $result.Text 'electron'
            if (Test-Path -LiteralPath (Join-Path $dir 'package.json')) {
                ensureVersion 'Electron (global)' (targetFor electron (getElectron $dir)) { getElectron $dir } { upgradeElectron global }
            }
        }
    }
}

# Handles only this Action reference in the current project's workflows; floating branches and SHAs cannot be resolved offline.
function getPypiActionMatches([string]$file) {
    $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    return [regex]::Matches($raw, '(?m)^[ \t]*(-[ \t]+)?uses:[ \t]*["'']?pypa/gh-action-pypi-publish@([^\s"''#]+)')
}
function getPypiActionVersion([string]$file) {
    $found = @(getPypiActionMatches $file)
    if ($found.Count -ne 1) { throw 'The number of references in the workflow has changed; cannot verify.' }
    $ref = $found[0].Groups[2].Value
    if ($ref -notmatch '^v(\d+\.\d+\.\d+)$') { throw "Reference [$ref] is not a comparable fixed tag." }
    return $Matches[1]
}
function upgradePypiActionRef([string]$file, [string]$ref) {
    $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    $pattern = '(?m)(^[ \t]*(-[ \t]+)?uses:[ \t]*["'']?pypa/gh-action-pypi-publish@)' + [regex]::Escape($ref) + '(?=[\s"''#]|$)'
    $regex = New-Object System.Text.RegularExpressions.Regex($pattern)
    $updated = $regex.Replace($raw, '${1}v1.14.3', 1)
    if ($updated -eq $raw) { throw "Could not locate reference [$ref] in the workflow." }
    Copy-Item -LiteralPath $file -Destination ($file + '.emudhra.' + (Get-Date -Format 'yyyyMMddHHmmss') + '.bak') -Force
    [IO.File]::WriteAllText($file, $updated, (New-Object Text.UTF8Encoding($false)))
}
function checkPypiAction {
    $dir = Join-Path $script:project_dir '.github\workflows'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $files = @()
    foreach ($pattern in @('*.yml', '*.yaml')) {
        $files += Get-ChildItem -LiteralPath $dir -Filter $pattern -File -ErrorAction SilentlyContinue
    }
    foreach ($file in $files) {
        $found = @(getPypiActionMatches $file.FullName)
        if ($found.Count -eq 0) { continue }
        $displayed = "Workflow [$($file.Name)]"
        if ($found.Count -gt 1) { fail 'pypi-publish GitHub Action' "$displayed contains multiple references; handle it manually."; continue }
        $ref = $found[0].Groups[2].Value
        if ($ref -match '^v(\d+\.\d+\.\d+)$') {
            ensureVersion "pypi-publish GitHub Action ($($file.Name))" '1.14.3' { getPypiActionVersion $file.FullName } { upgradePypiActionRef $file.FullName $ref }
        } elseif ($ref -match '^[0-9a-f]{7,40}$') {
            reportSkip 'pypi-publish GitHub Action' "$displayed uses a commit SHA reference; the version cannot be resolved, so handle it manually."
        } else {
            reportSkip 'pypi-publish GitHub Action' "In $displayed, reference [$ref] cannot be verified offline; switch to a fixed tag or confirm manually."
        }
    }
}
function getComposer([string]$scope = 'local') {
    $arguments = @('show', 'composer/ca-bundle', '--format=json')
    if ($scope -eq 'global') { $arguments = @('global') + $arguments }
    $result = readNative composer $arguments
    # Composer global first writes a directory-change notice to stderr; take the JSON object that follows.
    $json_start = $result.IndexOf('{')
    if ($json_start -lt 0) { throw 'Composer did not return parseable JSON.' }
    $result = $result.Substring($json_start)
    return (($result | ConvertFrom-Json).versions[0]).TrimStart('v')
}
function upgradeComposer([string]$scope = 'local') {
    $arguments = @('update', 'composer/ca-bundle', '--with-dependencies', '--no-interaction')
    if ($scope -eq 'global') { $arguments = @('global') + $arguments }
    runNative composer $arguments
}
function checkComposer {
    if (Test-Path -LiteralPath 'composer.lock') {
        $lock = Get-Content -LiteralPath 'composer.lock' -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@($lock.packages) + @($lock.'packages-dev') | Where-Object { $_.name -eq 'composer/ca-bundle' }) {
            ensureVersion 'Composer ca-bundle' (targetFor composer (getComposer)) { getComposer } { upgradeComposer }
        }
    }
    if (findTool composer) {
        # Global notices may go to stderr; the version query stays deterministic via --no-interaction.
        $probe = query composer @('global', 'show', 'composer/ca-bundle', '--format=json', '--quiet')
        if ($probe.Code -eq 0) {
            ensureVersion 'Composer ca-bundle (global)' (targetFor composer (getComposer global)) { getComposer global } { upgradeComposer global }
        }
    }
}
function getCastore {
    $raw = Get-Content -LiteralPath 'mix.lock' -Raw -Encoding UTF8
    if ($raw -match '"castore"\s*:\s*\{:hex,\s*:castore,\s*"([^"]+)"') { return $Matches[1] }
    throw 'Could not recognize the castore version in mix.lock.'
}
function upgradeCastore { runNative mix @('deps.update', 'castore') }
function checkCastore {
    if ((Test-Path -LiteralPath 'mix.lock') -and (Select-String -LiteralPath 'mix.lock' -Pattern '"castore"' -Quiet)) {
        ensureVersion castore '1.0.22' { getCastore } { upgradeCastore }
    }
}

# Ruby excon ships its own certificate bundle; update through Bundler when a Gemfile.lock exists, and check the global gem separately.
function getExcon([string]$scope = 'local') {
    if ($scope -eq 'global') {
        $result = query gem @('list', '-e', 'excon')
        if ($result.Code -eq 0 -and $result.Text -match '(?m)^excon \(([0-9][^,)]*)') { return $Matches[1] }
        return ''
    }
    if (-not (Test-Path -LiteralPath 'Gemfile.lock')) { return '' }
    $raw = Get-Content -LiteralPath 'Gemfile.lock' -Raw -Encoding UTF8
    if ($raw -match '(?m)^\s+excon \(([0-9][^)]*)\)') { return $Matches[1] }
    return ''
}
function upgradeExcon([string]$scope = 'local') {
    if ($scope -eq 'global') { runNative gem @('update', 'excon') }
    else { runNative bundle @('update', 'excon') }
}
function checkExcon {
    if ((Test-Path -LiteralPath 'Gemfile.lock') -and (Select-String -LiteralPath 'Gemfile.lock' -Pattern '^\s+excon \(' -Quiet)) {
        if (-not (findTool bundle)) { fail 'Ruby excon' 'The lockfile contains excon, but bundle was not found.' }
        else { ensureVersion 'Ruby excon' '1.8.0' { getExcon local } { upgradeExcon local } }
    }
    if (findTool gem) {
        $current = getExcon global
        if ($current) { ensureVersion 'Ruby excon (global)' '1.8.0' { getExcon global } { upgradeExcon global } }
    }
}

# The trust-manager default CA bundle is an image tag; this only reads the current project's Helm values/manifests and does not modify the cluster.
function trustPkgTags {
    $results = New-Object 'System.Collections.Generic.List[string]'
    $files = Get-ChildItem -LiteralPath $script:project_dir -Recurse -Depth 4 -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.yaml', '.yml', '.json') -and $_.FullName -notmatch '[\\/](\.git|node_modules|vendor)[\\/]' }
    foreach ($file in $files) {
        $flavor = ''
        foreach ($line in (Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match 'trust-pkg-debian-trixie') { $flavor = 'trust-pkg-debian-trixie' }
            elseif ($line -match 'trust-pkg-debian-bookworm') { $flavor = 'trust-pkg-debian-bookworm' }
            if ($line -match '(trust-pkg-debian-(?:trixie|bookworm):[0-9A-Za-z._-]+)') { $results.Add($Matches[1]); continue }
            if ($flavor -and ($line -match 'tag:\s*"?([0-9][0-9A-Za-z._-]*)')) { $results.Add(($flavor + ':' + $Matches[1])) }
        }
    }
    return @($results | Sort-Object -Unique)
}
function trustPkgGe([string]$current, [string]$minimum) {
    # A tag looks like 20250419-deb13u1.0; compare segment by segment: date, deb major version, u revision, and .N patch.
    $pattern = '^(\d+)-deb(\d+)u(\d+)(?:\.(\d+))?$'
    if ($current -notmatch $pattern) { return $false }
    $cdate = [long]$Matches[1]; $cmajor = [long]$Matches[2]; $crev = [long]$Matches[3]
    $cpatch = if ($Matches[4]) { [long]$Matches[4] } else { 0 }
    if ($minimum -notmatch $pattern) { return $false }
    $mdate = [long]$Matches[1]; $mmajor = [long]$Matches[2]; $mrev = [long]$Matches[3]
    $mpatch = if ($Matches[4]) { [long]$Matches[4] } else { 0 }
    if ($cdate -ne $mdate) { return ($cdate -gt $mdate) }
    if ($cmajor -ne $mmajor) { return ($cmajor -gt $mmajor) }
    if ($crev -ne $mrev) { return ($crev -gt $mrev) }
    return ($cpatch -ge $mpatch)
}
function checkCertManagerTrust {
    $tags = @(trustPkgTags)
    if ($tags.Count -eq 0) { reportSkip 'Kubernetes cert-manager trust bundle' 'No reference to the trust-manager default CA bundle was found in the current directory; verify the cluster side manually.'; return }
    $seen = @{}
    foreach ($tag in $tags) {
        if ($seen.ContainsKey($tag)) { continue }
        $seen[$tag] = $true
        $split = $tag.IndexOf(':')
        if ($split -lt 1) { continue }
        $flavor = $tag.Substring(0, $split); $version = $tag.Substring($split + 1)
        if ($flavor -eq 'trust-pkg-debian-trixie') { $minimum = '20250419-deb13u1.0' }
        elseif ($flavor -eq 'trust-pkg-debian-bookworm') { $minimum = '20250419-deb12u2.0' }
        else { continue }
        if (trustPkgGe $version $minimum) {
            reportSkip 'Kubernetes cert-manager trust bundle' "Reference [$tag] already satisfies [$minimum]."
        } else {
            fail 'Kubernetes cert-manager trust bundle' "Reference [$tag] is below [${flavor}:$minimum]; upgrade it through defaultPackageImage.tag in the Helm values; the script does not modify the cluster."
        }
    }
}
function getPerlCa { return readNative perl @('-MMozilla::CA', '-e', 'print $Mozilla::CA::VERSION') }
function upgradePerlCa {
    if (findTool cpanm) { runNative cpanm @('Mozilla::CA~>=20261020') }
    elseif (findTool cpan) {
        $old = $env:PERL_MM_USE_DEFAULT
        try { $env:PERL_MM_USE_DEFAULT = '1'; runNative cpan @('-i', 'Mozilla::CA') }
        finally { $env:PERL_MM_USE_DEFAULT = $old }
    } else { throw 'cpanm/cpan was not found.' }
}
function checkPerlCa {
    if (-not (findTool perl)) { return }
    $result = query perl @('-MMozilla::CA', '-e', 'print $Mozilla::CA::VERSION')
    if ($result.Code -eq 0) { ensureVersion 'Perl Mozilla::CA' '20261020' { getPerlCa } { upgradePerlCa } }
}

function bundleDate([string]$file) {
    $raw = Get-Content -LiteralPath $file -Raw
    if ($raw -match '(?m)^## Certificate data from Mozilla as of:\s*(.+?)\r?$') {
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AllowWhiteSpaces
        $date = [datetime]::ParseExact($Matches[1].Trim(), "ddd MMM d HH:mm:ss yyyy 'GMT'", [Globalization.CultureInfo]::InvariantCulture, $styles)
        return $date.ToString('yyyy.MM.dd', [Globalization.CultureInfo]::InvariantCulture)
    }
    throw 'Could not recognize the curl export date; the custom CA bundle was not overwritten.'
}
function upgradeBundle([string]$file) {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('emudhra-' + [guid]::NewGuid().ToString('N'))
    $staged = $file + '.emudhra-' + [guid]::NewGuid().ToString('N') + '.tmp'
    $old_protocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $old_protocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri 'https://curl.se/ca/cacert.pem' -OutFile $temporary
        $checksum = (Invoke-WebRequest -UseBasicParsing -Uri 'https://curl.se/ca/cacert.pem.sha256').Content
        $expected = ($checksum.Trim() -split '\s+')[0]
        if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $expected) { throw 'CA bundle SHA256 verification failed.' }
        if (-not (versionGe (bundleDate $temporary) '2026.10.20')) { throw 'The downloaded CA bundle is still too old.' }
        Copy-Item -LiteralPath $temporary -Destination $staged
        # Replace atomically swaps in the existing file while keeping a separate backup.
        $backup = $file + '.emudhra-' + [guid]::NewGuid().ToString('N') + '.bak'
        [IO.File]::Replace($staged, $file, $backup)
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $old_protocol
        foreach ($path in @($temporary, $staged)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    }
}
function checkCurlBundle {
    $candidates = @($env:CURL_CA_BUNDLE, $env:SSL_CERT_FILE, $env:REQUESTS_CA_BUNDLE,
        (Join-Path $script:project_dir 'cacert.pem'), (Join-Path $script:project_dir 'curl-ca-bundle.crt'))
    $curl = findTool curl
    if ($curl) { $candidates += Join-Path (Split-Path $curl) 'curl-ca-bundle.crt' }
    $seen = @{}
    foreach ($file in $candidates) {
        if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $file = (Resolve-Path -LiteralPath $file).Path
        if ($seen.ContainsKey($file)) { continue }
        $seen[$file] = $true
        $managed = $false
        foreach ($py in $script:python_list) {
            $owned = query $py @('-c', 'import certifi; print(certifi.where())')
            if ($owned.Code -eq 0 -and (Test-Path -LiteralPath $owned.Text)) {
                if ($file -eq (Resolve-Path -LiteralPath $owned.Text).Path) { $managed = $true; break }
            }
        }
        if ($managed) { continue }
        ensureVersion "curl CA bundle ($file)" '2026.10.20' { bundleDate $file } { upgradeBundle $file }
    }
}
function checkCfssl {
    if (-not (findTool git) -or -not (Test-Path -LiteralPath '.git')) { return }
    $remote = query git @('remote', 'get-url', 'origin')
    if ($remote.Text -notmatch 'cloudflare/cfssl_trust') { return }
    $marker = 'trust-store-2026.10.1'
    $ancestry = query git @('merge-base', '--is-ancestor', $marker, 'HEAD')
    if ($ancestry.Code -eq 0) { reportSkip 'CFSSL trust store' "Already contains fix tag [$marker]."; return }
    $current = readNative git @('describe', '--tags', '--match', 'trust-store-*', '--abbrev=0')
    if (versionGe ($current -replace '^trust-store-', '') '2026.10.1') { reportSkip 'CFSSL trust store' "Version [$current] already satisfies the requirement."; return }
    if (-not (beginUpdate 'CFSSL trust store' $current $marker)) { return }
    try {
        if (readNative git @('status', '--porcelain')) { throw 'The repository has uncommitted changes.' }
        runNative git @('fetch', 'origin', 'tag', $marker)
        runNative git @('merge', '--ff-only', $marker)
        runNative git @('merge-base', '--is-ancestor', $marker, 'HEAD')
        Write-Host "  Done [$marker]"
        $script:active_update = $false
        $script:update_log.Clear()
        $script:updated++
    } catch { throw }
}

# Linux/Unix-only items do not apply on native Windows; inside WSL/containers the Bash version must be run separately.
# Per-item functions are kept for future extension; Windows certutil of the same name is not a substitute for NSS.
function checkUbuntu { }
function checkDebian { }
function checkArch { }
function checkGentoo { }
function checkFedora { }
function checkChainguard { }
function checkAlpine { }
function checkGuix { }
function checkHomebrew { }
function checkNss {
    if (findTool pkg-config) {
        $result = query pkg-config @('--modversion', 'nss')
        if ($result.Code -eq 0) {
            ensureVersion NSS '3.131.1' { readNative pkg-config @('--modversion', 'nss') } {
                throw 'A standalone NSS was detected; upgrade it with the Windows SDK/package manager that provides it.'
            }
        }
    }
}

# Platform-specific items also keep their own entry points; invokeCheck reports why they do not apply.
function checkDevuan { }
function checkFreebsdCaroot { }
function checkFreebsd { }
function checkFreedesktop { }
function checkOmnios { }
function checkOpenbsd { }
function checkNetbsd { }
function checkOracleLinux { }
function checkRhel { }
function checkBottlerocket { reportSkip Bottlerocket 'Still pending in the patch table; no fixed version is configured yet.' }
function checkGodot { reportSkip Godot 'Still pending in the patch table; no fixed version is configured yet.' }
function checkLibreOffice { reportSkip LibreOffice 'Still pending in the patch table; no fixed version is configured yet.' }

# Erlang certifi is a Hex package; only the rebar/mix dependencies of the current directory are handled, Python certifi is untouched.
function erlangCertifiPresent {
    $hasMix = (Test-Path -LiteralPath 'mix.lock') -and (Select-String -LiteralPath 'mix.lock' -Pattern '"certifi"' -Quiet)
    $hasRebarLock = (Test-Path -LiteralPath 'rebar.lock') -and (Select-String -LiteralPath 'rebar.lock' -Pattern 'certifi' -Quiet)
    $hasRebarConfig = (Test-Path -LiteralPath 'rebar.config') -and (Select-String -LiteralPath 'rebar.config' -Pattern '\{certifi,' -Quiet)
    return ($hasMix -or $hasRebarLock -or $hasRebarConfig)
}
function getErlangCertifi {
    $version = ''
    if (Test-Path -LiteralPath 'mix.lock') {
        $raw = Get-Content -LiteralPath 'mix.lock' -Raw -Encoding UTF8
        if ($raw -match '"certifi"\s*:\s*\{:hex,\s*:certifi,\s*"([^"]+)"') { $version = $Matches[1] }
    }
    if (-not $version -and (Test-Path -LiteralPath 'rebar.lock')) {
        $raw = Get-Content -LiteralPath 'rebar.lock' -Raw -Encoding UTF8
        if ($raw -match '\{<<"certifi">>,\{pkg,<<"certifi">>,<<"([^"]+)">>\}') { $version = $Matches[1] }
    }
    if (-not $version -and (Test-Path -LiteralPath 'rebar.config')) {
        $raw = Get-Content -LiteralPath 'rebar.config' -Raw -Encoding UTF8
        if ($raw -match '\{certifi,\s*"([^"]+)"') { $version = $Matches[1] }
    }
    if (-not $version) { throw 'Could not parse the certifi version from the lockfile.' }
    return $version
}
function upgradeErlangCertifi {
    if ((Test-Path -LiteralPath 'mix.lock') -and (Select-String -LiteralPath 'mix.lock' -Pattern '"certifi"' -Quiet)) {
        runNative mix @('deps.update', 'certifi'); return
    }
    if (findTool rebar3) { runNative rebar3 @('upgrade', 'certifi'); return }
    throw 'The current directory has a certifi dependency, but rebar3 was not found.'
}
function checkErlangCertifi {
    if (-not (erlangCertifiPresent)) { return }
    try { $null = getErlangCertifi } catch { fail 'Erlang certifi' $_.Exception.Message; return }
    ensureVersion 'Erlang certifi' '2.18.0' { getErlangCertifi } { upgradeErlangCertifi }
}

# Java uses the full runtime.version; 8u511 is normalized to 8.0.511, and the build number after + does not participate in patch comparison.
function normalizeJava([string]$version) {
    $version = ($version -split '\+')[0]
    if ($version -match '^1\.8\.0_(\d+)(?:-b\d+)?$') { return "8.0.$($Matches[1])" }
    return $version
}
function javaTarget([string]$version) {
    switch (($version -split '\.')[0]) {
        8 { return '8.0.511' }; 11 { return '11.0.33.0.2' }; 17 { return '17.0.21.0.2' }
        21 { return '21.0.13.0.2' }; 25 { return '25.0.5.0.2' }; 27 { return '27.0.1.0.2' }
        default { throw "No fixed version is listed for branch [$version]; use a branch supported by the original vendor." }
    }
}
function getJava {
    $details = readNative java @('-XshowSettings:properties', '-version')
    if ($details -match '(?m)^\s*java\.runtime\.version = (.+?)\r?$') { return normalizeJava $Matches[1] }
    if ($details -match '(?m)^\s*java\.version = (.+?)\r?$') { return normalizeJava $Matches[1] }
    throw 'Could not read the full runtime version of the active Java.'
}
function upgradeJava {
    $details = readNative java @('-XshowSettings:properties', '-version')
    $major = ((getJava) -split '\.')[0]
    $vendor = if ($details -match '(?m)^\s*java\.vendor = (.+?)\r?$') { $Matches[1] } else { '' }
    $java_dir = if ($details -match '(?m)^\s*java\.home = (.+?)\r?$') { $Matches[1] } else { '' }
    if (-not $java_dir) { throw 'Could not locate the active Java installation directory.' }
    $binary = Join-Path $java_dir 'bin\java.exe'
    # The JDK vendor is not changed; only an existing same-vendor, same-major version product in the original manager is upgraded.
    $id = ''; $scoop = ''; $choco = ''
    if ($vendor -match 'Adoptium|Temurin') {
        $id = "EclipseAdoptium.Temurin.$major.JDK"; $scoop = "temurin$major-jdk"; $choco = "temurin$major"
    } elseif ($vendor -match 'Microsoft') {
        $id = "Microsoft.OpenJDK.$major"; $scoop = "microsoft$major-jdk"; $choco = "microsoft-openjdk$major"
    } elseif ($vendor -match 'Oracle') {
        $id = "Oracle.JDK.$major"; $scoop = "oracle$major-jdk"; $choco = "jdk$major"
    } else { throw "Could not identify the installation source for JDK vendor [$vendor]; upgrade through the original vendor." }
    upgradeOwned $binary $id $scoop $choco
}
function checkJava {
    if (findTool java) { ensureVersion Java (javaTarget (getJava)) { getJava } { upgradeJava } }
}
function getPixi { return versionOf (readNative pixi @('--version')) }
function upgradePixi {
    $result = updateQuery pixi @('self-update')
    if ($result.Code -ne 0) { upgradeOwned pixi 'prefix-dev.pixi' pixi pixi }
}
function checkPixi { if (findTool pixi) { ensureVersion pixi '0.82.1' { getPixi } { upgradePixi } } }
function getClaude { return versionOf (readNative claude @('--version')) }
function upgradeClaude {
    $result = updateQuery claude @('update')
    # Manager installations sometimes report success without updating the binary, so the version is checked again before falling back.
    if ($result.Code -eq 0 -and (versionGe (getClaude) '2.1.303')) { return }
    upgradeOwned claude 'Anthropic.ClaudeCode' claude-code claude-code
}
function checkClaude { if (findTool claude) { ensureVersion 'Claude Code' '2.1.303' { getClaude } { upgradeClaude } } }
function getMise { return versionOf (readNative mise @('--version')) }
function upgradeMise {
    $result = updateQuery mise @('self-update', '--yes', '--no-plugins')
    if ($result.Code -ne 0) { upgradeOwned mise 'jdx.mise' mise mise }
}
function checkMise { if (findTool mise) { ensureVersion mise '2026.10.17' { getMise } { upgradeMise } } }
function getDeno { return versionOf (readNative deno @('--version')) }
function upgradeDeno {
    $result = updateQuery deno @('upgrade')
    if ($result.Code -ne 0) { upgradeOwned deno 'DenoLand.Deno' deno deno }
}
function checkDeno { if (findTool deno) { ensureVersion Deno '2.9.8' { getDeno } { upgradeDeno } } }

function getBun { return versionOf (readNative bun @('--version')) }
function upgradeBun {
    # The official recommendation is for package-manager installs to use the original manager; canary is not accepted as proof of a fix, and self-update switches back to stable.
    $path = findTool bun
    if (($path -match '(?i)[\\/]scoop[\\/]') -or ($env:ChocolateyInstall -and $path.StartsWith($env:ChocolateyInstall, [StringComparison]::OrdinalIgnoreCase))) {
        upgradeOwned bun 'Oven-sh.Bun' bun bun; return
    }
    $result = updateQuery bun @('upgrade', '--stable')
    if ($result.Code -ne 0) { upgradeOwned bun 'Oven-sh.Bun' bun bun }
}
function checkBun { if (findTool bun) { ensureVersion Bun '1.4.4' { getBun } { upgradeBun } } }

# Dart / Flutter: when Flutter ships its own Dart, only the Flutter SDK is checked so the bundled Dart is not treated as a separate installation.
function getFlutter {
    $result = query flutter @('--version')
    if ($result.Code -ne 0) { throw "[flutter]: $($result.Text)" }
    if ($result.Text -match '(?m)^Flutter ([0-9]+\.[0-9]+\.[0-9]+)') { return $Matches[1] }
    throw 'Could not parse the Flutter SDK version from flutter --version.'
}
function getDart {
    $result = query dart @('--version')
    if ($result.Code -ne 0) { throw "[dart]: $($result.Text)" }
    return versionOf $result.Text
}
function dartBundledByFlutter {
    $dart = findTool dart
    $flutter = findTool flutter
    if (-not $dart -or -not $flutter) { return $false }
    return ((Split-Path $dart) -eq (Split-Path $flutter))
}
function upgradeFlutter { runNative flutter @('upgrade') }
function upgradeDart {
    if ((findTool flutter) -and (dartBundledByFlutter)) { runNative flutter @('upgrade'); return }
    upgradeOwned dart 'Google.DartSDK' dart-sdk dart-sdk
}
function checkDartFlutter {
    if (findTool flutter) { ensureVersion Flutter '3.47.8' { getFlutter } { upgradeFlutter } }
    if (findTool dart) {
        if ((findTool flutter) -and (dartBundledByFlutter)) { reportSkip Dart 'Provided by the Flutter SDK; checked/upgraded with Flutter.' }
        else { ensureVersion Dart '3.13.7' { getDart } { upgradeDart } }
    }
}

function getConda { return versionOf (readNative conda @('--version')) }
function upgradeConda {
    # Official update command; keep the user's existing channel configuration and do not add a default channel.
    runNative conda @('update', '--name', 'base', '--yes', 'conda')
}
function checkConda { if (findTool conda) { ensureVersion Conda '26.9.4' { getConda } { upgradeConda } } }

# Obsidian is an Electron app: the application itself must be updated; updating system certificates is not a substitute.
function getObsidian {
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Obsidian\Obsidian.exe'
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Obsidian\Obsidian.exe'
    }
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Obsidian\Obsidian.exe' }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) { return (versionOf (Get-Item -LiteralPath $path).VersionInfo.ProductVersion) }
    }
    throw 'No Obsidian installation record was found.'
}
function upgradeObsidian {
    if (findTool winget) {
        $listed = query winget @('list', '--id', 'Obsidian.Obsidian', '--exact', '--disable-interactivity')
        if ($listed.Code -eq 0 -and $listed.Text.Contains('Obsidian.Obsidian')) {
            runNative winget @('upgrade', '--id', 'Obsidian.Obsidian', '--exact', '--disable-interactivity'); return
        }
    }
    throw 'Cannot update Obsidian automatically; use the in-app update or the official installer, and restart the app after upgrading.'
}
function checkObsidian {
    try { $null = getObsidian } catch { return }
    ensureVersion Obsidian '1.14.5' { getObsidian } { upgradeObsidian }
}

# VS Code is also an Electron app; Insiders and stable are not mixed, only stable is compared here.
function getVSCode {
    $result = query code @('--version')
    if ($result.Code -ne 0) { throw "[code]: $($result.Text)" }
    $first = ($result.Text -split '\r?\n')[0]
    if ($first) { return $first.Trim() }
    throw 'code --version returned no version.'
}
function upgradeVSCode { upgradeOwned code 'Microsoft.VisualStudioCode' vscode vscode }
function checkVSCode {
    if (findTool code) { ensureVersion 'Visual Studio Code' '1.143.1' { getVSCode } { upgradeVSCode } }
}

function getGitHubCli { return versionOf (readNative gh @('--version')) }
function upgradeGitHubCli { upgradeOwned gh 'GitHub.cli' gh gh }
function checkGitHubCli {
    if (findTool gh) { ensureVersion 'GitHub CLI' '2.102.1' { getGitHubCli } { upgradeGitHubCli } }
}

# mitmproxy may be installed by pipx / uv tool / pip, etc.; return to the original install entry point first.
function getMitmproxy {
    if (findTool mitmproxy) { return versionOf (readNative mitmproxy @('--version')) }
    if (findTool mitmdump) { return versionOf (readNative mitmdump @('--version')) }
    throw 'mitmproxy/mitmdump was not found.'
}
function upgradeMitmproxy {
    if (findTool pipx) {
        $pipx = query pipx @('list', '--short')
        if ($pipx.Text -match '(?m)^mitmproxy\s') { runNative pipx @('upgrade', 'mitmproxy'); return }
    }
    if (findTool uv) {
        $uvTools = query uv @('tool', 'list')
        if ($uvTools.Text -match '(?m)^mitmproxy\s') { runNative uv @('tool', 'upgrade', 'mitmproxy'); return }
    }
    foreach ($py in $script:python_list) {
        $probe = query $py @('-c', "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('mitmproxy') else 1)")
        if ($probe.Code -eq 0) { upgradePythonPackage $py mitmproxy '12.3'; return }
    }
    throw 'Could not determine how mitmproxy was installed; upgrade it with pipx / uv tool / pip / your package manager.'
}
function checkMitmproxy {
    if (-not (findTool mitmproxy) -and -not (findTool mitmdump)) { return }
    ensureVersion mitmproxy '12.3' { getMitmproxy } { upgradeMitmproxy }
}

# ArgoCD CLI and in-cluster server versions are separate; the page lists versions on the three stable release lines 3.3 / 3.4 / 3.5.
function argocdTarget([string]$version) {
    $dot = $version.LastIndexOf('.')
    if ($dot -lt 1) { throw "Branch [$version] has no listed stable fixed version (3.6 currently only has RCs; pre-releases are not accepted as proof of a fix)." }
    $branch = $version.Substring(0, $dot)
    switch ($branch) {
        '3.3' { return '3.3.18' }
        '3.4' { return '3.4.12' }
        '3.5' { return '3.5.6' }
        default { throw "Branch [$version] has no listed stable fixed version (3.6 currently only has RCs; pre-releases are not accepted as proof of a fix)." }
    }
}
function getArgocd { return versionOf (readNative argocd @('version', '--client', '--short')) }
function upgradeArgocd { upgradeOwned argocd 'Argoproj.ArgoCD' argocd argocd }
function checkArgocdServer {
    if (-not (findTool kubectl)) { reportSkip 'ArgoCD server' 'kubectl was not found; verify the server version on the cluster side according to the deployment method.'; return }
    $result = query kubectl @('-n', 'argocd', 'get', 'deployment', 'argocd-server', '-o', 'jsonpath={.spec.template.spec.containers[0].image}')
    if ($result.Code -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        reportSkip 'ArgoCD server' 'Could not read the argocd-server deployment; the server version cannot be verified.'; return
    }
    $image = $result.Text.Trim()
    if ($image -match ':v?(\d+\.\d+\.\d+)$') {
        $server = $Matches[1]
        try { $minimum = argocdTarget $server } catch { fail 'ArgoCD server' "The release line of image [$image] has no stable fixed version (3.6 currently only has RCs); manual confirmation is required."; return }
        if (versionGe $server $minimum) { reportSkip 'ArgoCD server' "Image [$image] already satisfies [$minimum]." }
        else { fail 'ArgoCD server' "Image [$image] is below [$minimum]; upgrade it through Helm/deployment manifests, the script does not modify the cluster automatically." }
    } else {
        reportSkip 'ArgoCD server' "Image [$image] does not use a comparable version tag; confirm manually."
    }
}
function checkArgocd {
    if (findTool argocd) {
        try {
            $current = getArgocd
            $minimum = argocdTarget $current
            ensureVersion 'ArgoCD CLI' $minimum { getArgocd } { upgradeArgocd }
        } catch { fail 'ArgoCD CLI' $_.Exception.Message }
    }
    if (findTool kubectl) { checkArgocdServer }
}

# Docker Desktop is a separate application; the docker Engine/CLI version cannot stand in for the Desktop version.
function getDockerDesktop {
    $result = query docker @('desktop', 'version')
    if ($result.Code -eq 0) { return (versionOf $result.Text) }
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop'
    )) {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($item -and $item.DisplayVersion) { return (versionOf $item.DisplayVersion) }
    }
    $exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path -LiteralPath $exe) { return (versionOf (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion) }
    throw 'No Docker Desktop installation record was found.'
}
function upgradeDockerDesktop {
    # Upgrade only an installed Docker Desktop; do not overwrite unknown sources with the official installer.
    if (findTool winget) {
        $listed = query winget @('list', '--id', 'Docker.DockerDesktop', '--exact', '--disable-interactivity')
        if ($listed.Code -eq 0 -and $listed.Text.Contains('Docker.DockerDesktop')) {
            runNative winget @('upgrade', '--id', 'Docker.DockerDesktop', '--exact', '--disable-interactivity'); return
        }
    }
    throw 'Docker Desktop cannot be updated automatically; use the in-app update and restart Docker Desktop after upgrading.'
}
function checkDockerDesktop {
    try { $null = getDockerDesktop } catch { return }
    ensureVersion 'Docker Desktop' '4.96.2' { getDockerDesktop } { upgradeDockerDesktop }
}

# Docker Engine / CLI is handled separately from Desktop; Desktop-managed installations are upgraded with Desktop and not processed twice.
function getDockerEngine {
    $result = query docker @('version', '--format', '{{.Server.Version}}')
    if ($result.Code -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) { return '' }
    try { return (versionOf $result.Text) } catch { return '' }
}
function getDockerCli { return versionOf (readNative docker @('--version')) }
function upgradeDockerEngine {
    throw 'No Docker Engine that can be upgraded automatically was found; on Windows the Engine is managed by Docker Desktop or WSL.'
}
function upgradeDockerCli { upgradeOwned docker 'Docker.DockerCLI' docker docker-cli }
function checkDockerEngine {
    if (-not (findTool docker)) { return }
    try { $null = getDockerDesktop; reportSkip 'Docker Engine' 'Managed by Docker Desktop; upgraded with Desktop.'; return } catch { }
    $current = getDockerEngine
    if (-not $current) { fail 'Docker Engine' 'Cannot connect to the Docker daemon, so the Engine version cannot be verified.'; return }
    ensureVersion 'Docker Engine' '29.9.2' { getDockerEngine } { upgradeDockerEngine }
}
function checkDockerCli {
    if (-not (findTool docker)) { return }
    try { $null = getDockerDesktop; reportSkip 'Docker CLI' 'Managed by Docker Desktop; upgraded with Desktop.'; return } catch { }
    ensureVersion 'Docker CLI' '29.9.2' { getDockerCli } { upgradeDockerCli }
}

# The Git for Windows version string is X.Y.Z.windows.N; it cannot be handled like a plain dot-separated version that takes only the first three segments.
function getGitForWindows {
    $result = query git @('--version')
    if ($result.Code -ne 0) { throw "[git]: $($result.Text)" }
    if ($result.Text -match '([0-9]+\.[0-9]+\.[0-9]+)\.windows\.([0-9]+)') { return "$($Matches[1]).$($Matches[2])" }
    return ''
}
function upgradeGitForWindows {
    if (findTool winget) {
        $listed = query winget @('list', '--id', 'Git.Git', '--exact', '--disable-interactivity')
        if ($listed.Code -eq 0 -and $listed.Text.Contains('Git.Git')) {
            runNative winget @('upgrade', '--id', 'Git.Git', '--exact', '--disable-interactivity'); return
        }
    }
    if (findTool choco) { runNative choco @('upgrade', 'git', '-y'); return }
    if (findTool scoop) { runNative scoop @('update', 'git'); return }
    throw 'winget/choco/scoop was not found; upgrade with the original Git for Windows installer.'
}
function checkGitForWindows {
    if (-not (findTool git)) { return }
    try { $current = getGitForWindows } catch { fail 'Git for Windows' $_.Exception.Message; return }
    if (-not $current) { reportSkip 'Git for Windows' 'The current git has no windows version suffix, so it is not Git for Windows.'; return }
    ensureVersion 'Git for Windows' '2.56.0.3' { getGitForWindows } { upgradeGitForWindows }
}

# Every handler without a detection result has a specific reason; --check no longer skips silently.
$script:skip_reasons = @{
    checkUbuntu = @('Ubuntu CA package', 'Does not apply on native Windows; run the Bash version separately inside WSL.')
    checkDebian = @('Debian CA package', 'Does not apply on native Windows.')
    checkDevuan = @('Devuan CA package', 'Does not apply on native Windows.')
    checkFreebsdCaroot = @('FreeBSD caroot', 'Does not apply on native Windows.')
    checkFreebsd = @('FreeBSD ca_root_nss', 'Does not apply on native Windows.')
    checkFreedesktop = @('Freedesktop SDK', 'Does not apply on native Windows; inside Linux/WSL use the Bash version to check Flatpak runtimes.')
    checkOmnios = @('OmniOS web/ca-bundle', 'Does not apply on native Windows.')
    checkOpenbsd = @('OpenBSD cert.pem', 'Does not apply on native Windows; run the Bash version on OpenBSD.')
    checkNetbsd = @('NetBSD ca-certificates', 'Does not apply on native Windows; run the Bash version on NetBSD.')
    checkOracleLinux = @('Oracle Linux CA package', 'Does not apply on native Windows.')
    checkRhel = @('RHEL CA package', 'Does not apply on native Windows.')
    checkJava = @('Java', 'java was not found on PATH.')
    checkPixi = @('pixi', 'pixi was not found on PATH.')
    checkClaude = @('Claude Code', 'claude was not found on PATH.')
    checkMise = @('mise', 'mise was not found on PATH.')
    checkDeno = @('Deno', 'deno was not found on PATH.')
    checkObsidian = @('Obsidian', 'No recognizable Obsidian installation was found.')
    checkVSCode = @('Visual Studio Code', 'code was not found on PATH.')
    checkGitHubCli = @('GitHub CLI', 'gh was not found on PATH.')
    checkMitmproxy = @('mitmproxy', 'mitmproxy/mitmdump was not found on PATH.')
    checkBun = @('Bun', 'bun was not found on PATH.')
    checkDartFlutter = @('Dart / Flutter', 'dart or flutter was not found on PATH.')
    checkConda = @('Conda', 'conda was not found on PATH.')
    checkArgocd = @('ArgoCD CLI', 'argocd was not found on PATH.')
    checkDockerDesktop = @('Docker Desktop', 'No Docker Desktop installation record was found.')
    checkDockerEngine = @('Docker Engine', 'docker was not found on PATH, or no verifiable Engine can be connected.')
    checkDockerCli = @('Docker CLI', 'docker was not found on PATH.')
    checkGitForWindows = @('Git for Windows', 'The current git is not Git for Windows, or git was not found.')
    checkPypiAction = @('pypi-publish GitHub Action', 'The workflows of the current project contain no reference to this Action.')
    checkArch = @('Arch CA package', 'Does not apply on native Windows.')
    checkGentoo = @('Gentoo CA package', 'Does not apply on native Windows.')
    checkFedora = @('Fedora CA package', 'Does not apply on native Windows.')
    checkChainguard = @('Chainguard CA package', 'Does not apply on native Windows.')
    checkAlpine = @('Alpine CA package', 'Does not apply on native Windows.')
    checkHomebrew = @('Homebrew CA package', 'Does not apply on native Windows.')
    checkGuix = @('GNU Guix', 'Does not apply on native Windows.')
    checkNss = @('NSS', 'No standalone NSS library recognizable by pkg-config was found.')
    checkCurlBundle = @('curl CA bundle', 'No separately handled certificate file was found; files managed by certifi are checked by the certifi item.')
    checkCfssl = @('CFSSL trust store', 'The current directory is not a recognizable cloudflare/cfssl_trust Git repository, or git is not on PATH.')
    checkGo = @('Go', 'go was not found on PATH.')
    checkNode = @('Node.js', 'node was not found on PATH.')
    checkPip = @('pip', 'No usable Python/pip environment was found in the checked scope.')
    checkCertifi = @('Python certifi', 'No usable Python/certifi environment was found in the checked scope.')
    checkPythonRuntime = @('Python runtime', 'No usable Python interpreter was found in the checked scope.')
    checkUv = @('uv', 'uv was not found on PATH.')
    checkRustlsWebpki = @('rustls-webpki', 'The current directory has no recognizable Cargo.lock containing this library.')
    checkWebpkiRoots = @('webpki-roots', 'The current directory has no recognizable Cargo.lock containing this library.')
    checkWebpkiRootCerts = @('webpki-root-certs', 'The current directory has no recognizable Cargo.lock containing this library.')
    checkRustup = @('Rustup', 'rustup was not found on PATH.')
    checkElectron = @('Electron', 'No recognizable installation record was found in the current directory or the queryable npm global directory.')
    checkComposer = @('Composer ca-bundle', 'No recognizable installation record was found in the current project or the queryable Composer global installation.')
    checkCastore = @('Elixir castore', 'The current directory has no mix.lock containing castore.')
    checkExcon = @('Ruby excon', 'The current project has no recognizable excon dependency and no global gem was found.')
    checkCertManagerTrust = @('Kubernetes cert-manager trust bundle', 'No reference to the trust-manager default CA bundle was found in the current directory.')
    checkErlangCertifi = @('Erlang certifi', 'The current directory has no recognizable rebar/mix certifi dependency.')
    checkPerlCa = @('Perl Mozilla::CA', 'Perl was not found, or the active Perl cannot import Mozilla::CA.')
}

# Main flow: run each item in turn; a failure in one item does not block the items after it.
# The fixed finalized time represents the table.patched baseline snapshot; the current time at startup is not passed off as the update time.
$script:finalized_at = '2026-10-25 19:32:30 Australia/Sydney (UTC+11:00)'
Write-Host "eMudhra fix script | Finalized at: $script:finalized_at"
if ($env:EMUDHRA_BADARGS -or $env:EMUDHRA_MODE -notin @('', '--check', '--help', '-h', $null)) {
    [Console]::Error.WriteLine('Unknown argument. Usage: emudhrafix.cmd [--check]')
    exit 2
}
if ($env:EMUDHRA_MODE -eq '--help' -or $env:EMUDHRA_MODE -eq '-h') {
    Write-Host 'Usage: emudhrafix.cmd [--check]'
    Write-Host 'Checks system tools and the runtime current directory; --check only detects, no upgrade.'
    exit 0
}
Write-Host "Scope: system tools and current directory [$script:project_dir]. Detecting Python environments, please wait..."
if ($script:check_only) { Write-Host '[Check mode]' }
collectPython
Write-Host 'Environment detection complete; checking items in patch table order...'
foreach ($handler in @(
    'checkUbuntu',
    'checkDebian',
    'checkDevuan',
    'checkArch',
    'checkGentoo',
    'checkFedora',
    'checkFreebsdCaroot',
    'checkFreebsd',
    'checkFreedesktop',
    'checkChainguard',
    'checkAlpine',
    'checkGuix',
    'checkOmnios',
    'checkOpenbsd',
    'checkNetbsd',
    'checkOracleLinux',
    'checkRhel',
    'checkBottlerocket',
    'checkNss',
    'checkCurlBundle',
    'checkCfssl',
    'checkHomebrew',
    'checkGo',
    'checkJava',
    'checkNode',
    'checkPythonRuntime',
    'checkCertifi',
    'checkPip',
    'checkUv',
    'checkPixi',
    'checkRustlsWebpki',
    'checkWebpkiRoots',
    'checkWebpkiRootCerts',
    'checkRustup',
    'checkElectron',
    'checkBun',
    'checkDartFlutter',
    'checkClaude',
    'checkArgocd',
    'checkDockerDesktop',
    'checkDockerEngine',
    'checkDockerCli',
    'checkGitForWindows',
    'checkComposer',
    'checkCastore',
    'checkExcon',
    'checkCertManagerTrust',
    'checkErlangCertifi',
    'checkMise',
    'checkPypiAction',
    'checkPerlCa',
    'checkDeno',
    'checkConda',
    'checkObsidian',
    'checkVSCode',
    'checkGodot',
    'checkGitHubCli',
    'checkLibreOffice',
    'checkMitmproxy'
)) { invokeCheck $handler }
Write-Host "Done: $script:updated upgraded; $script:pending pending; $script:skipped skipped; $script:errors errors/unverified."
if ($script:errors -gt 0 -or $script:pending -gt 0) { exit 1 }
exit 0
