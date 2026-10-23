#!/usr/bin/env bash
# eMudhra fix tool; baseline source: https://emudhra.we-have-a-problem.com/
# Requires Bash 3.2+; do not run with sh. The finalized time is the baseline snapshot time, not the time of each run.
SCRIPT_FINALIZED_AT='2026-10-23 15:22:30 Australia/Sydney (UTC+11:00)'
# Checks only tools on PATH and the starting directory; project upgrades respect existing constraints and package sources.
# --check shows skip reasons; in update mode items already compliant or not installed stay quiet.

has() { command -v "$1" >/dev/null 2>&1; }
displayIndented() {
    # Strip terminal control characters to prevent screen clearing; the full raw content is kept in the failure log.
    LC_ALL=C awk -v prefix="${1-    }" '{
        gsub(/\033\[[0-?]*[ -/]*[@-~]/, "");
        gsub(/[\000-\010\013\014\016-\037\177]/, "");
        sub(/\r$/, ""); gsub(/\r/, "\n" prefix); print prefix $0
    }' >&2
}
reportSkip() {
    reported=$((${reported:-0} + 1))
    if [[ ${check_only:-0} = 1 ]]; then
        printf '    Skipped [%s]: %s\n' "$1" "$2"
        skipped=$((${skipped:-0} + 1))
    fi
}
fail() {
    local indent='' saved_log
    [[ ${active_update:-0} = 1 ]] && indent='  '
    printf 'Error [%s]: %s\n' "$1" "$2" | displayIndented "$indent"
    if [[ ${active_update:-0} = 1 && -s ${update_log:-/nonexistent} ]]; then
        printf '    Command log:\n' >&2
        displayIndented '      ' <"$update_log"
        saved_log=$(mktemp "${TMPDIR:-/tmp}/emudhra-error.XXXXXX")
        if [[ -n $saved_log ]] && cp "$update_log" "$saved_log"; then
            printf '    Full log: %s\n' "$saved_log" >&2
        else printf '    Failed to save the log file\n' >&2; fi
    fi
    active_update=0
    errors=$((${errors:-0} + 1)); reported=$((${reported:-0} + 1))
}
versionOf() { sed -nE 's/^[^0-9]*([0-9]+(\.[0-9]+)*([-+][A-Za-z0-9._-]+)?).*/\1/p' | head -n 1; }

# Compares numeric segments in order; pre-release versions are not accepted as fixed versions. Distributions use their own native comparators.
versionGe() {
    [[ $1 =~ ^[0-9]+(\.[0-9]+)*(\+[A-Za-z0-9.-]+)?$ ]] || return 1
    awk -v a="${1%%+*}" -v b="$2" 'BEGIN {
        na=split(a,x,"."); nb=split(b,y,"."); n=na>nb?na:nb;
        for(i=1;i<=n;i++){if(x[i]+0>y[i]+0)exit 0;if(x[i]+0<y[i]+0)exit 1}exit 0
    }'
}
targetFor() {
    local kind=$1 v=$2 major=${2%%.*} rest=${2#*.}
    case "$kind" in
        go) case "$v" in 1.26.*) echo 1.26.10;; *) echo 1.27.3;; esac;;
        node) case "$major" in 22) echo 22.23.4;; 24) echo 24.22.1;; *) echo 26.12.1;; esac;;
        electron) case "$major" in 42) echo 42.11.16;; 43) echo 43.8.1;; *) echo 44.9.1;; esac;;
        composer) case "$v" in 1.4.*) echo 1.4.16;; *) echo 1.6.0;; esac;;
    esac
}
rootRun() {
    if [[ $(id -u) = 0 ]]; then "$@"
    elif has sudo; then sudo -- "$@"
    elif [[ $(uname -s) = OpenBSD ]] && has doas; then doas "$@"
    else echo 'Root privileges are required and sudo/doas was not found.' >&2; return 1; fi
}
runQuiet() {
    local rc
    "$@" >"$temp_dir/command.log" 2>&1; rc=$?
    {
        printf 'Command: '; printf '%q ' "$@"; printf '\nExit code: %s\n' "$rc"
        cat "$temp_dir/command.log"; printf '\n'
    } >>"$update_log"
    return "$rc"
}
beginUpdate() {
    reported=$((${reported:-0} + 1))
    if [[ $check_only = 1 ]]; then
        printf 'Pending upgrade [%s]: [%s] → at least [%s]\n' "$1" "$2" "$3"
        pending=$((pending + 1)); return 1
    fi
    active_update=1
    update_log="$temp_dir/update.log"
    : >"$update_log"
    printf 'Found [%s], current [%s], upgrading to at least [%s]...\n' "$1" "$2" "$3"
}
finishUpdate() { printf '  Done [%s]\n' "$1"; updated=$((updated + 1)); active_update=0; }
updateFailed() { fail "$1" "${2:-Upgrade failed; fix not confirmed. Full command log follows.}"; }

# getter must print the current version; updater must not install items that were not already present.
ensureVersion() {
    local label=$1 minimum=$2 getter=$3 updater=$4 current after
    shift 4
    current=$("$getter" "$@") || { fail "$label" 'Could not read the installed version.'; return; }
    [[ -n $current ]] || { fail "$label" 'Version output is empty.'; return; }
    if versionGe "$current" "$minimum"; then reportSkip "$label" "Version [$current] already satisfies [$minimum]."; return; fi
    beginUpdate "$label" "$current" "$minimum" || return
    if runQuiet "$updater" "$@"; then
        hash -r
        after=$("$getter" "$@")
        if versionGe "$after" "$minimum"; then finishUpdate "$after"
        else updateFailed "$label" "Still [$after] after the upgrade; package sources, version constraints, or PATH may still point to the old version."; fi
    else updateFailed "$label"; fi
}

# Native system package comparison and upgrade. Queries return installed packages only; APT does not substitute source versions for distribution versions.
pkgVersion() {
    case "$1" in
        apt) dpkg-query -W -f='${Status}\t${Version}\n' "$2" 2>/dev/null | awk '$1=="install"&&$2=="ok"&&$3=="installed"{print $4}';;
        pacman) pacman -Q "$2" 2>/dev/null | awk '{print $2}';;
        apk) apk info -v "$2" 2>/dev/null | sed -n "s/^$2-//p" | head -n 1;;
        rpm) rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$2" 2>/dev/null;;
        brew) brew list --versions "$2" 2>/dev/null | awk '{print $NF}';;
        gentoo) local p; for p in /var/db/pkg/app-misc/ca-certificates-*; do
            [[ -d $p ]] && printf '%s\n' "${p##*/ca-certificates-}"; done;;
    esac
}
pkgGe() {
    local manager=$1 current=$2 minimum=$3 comparison
    case "$manager" in
        apt) dpkg --compare-versions "$current" ge "$minimum";;
        pacman)
            comparison=$(vercmp "$current" "$minimum") || return 1
            [[ $comparison =~ ^-?[0-9]+$ ]] && [[ $comparison -ge 0 ]];;
        apk)
            comparison=$(apk version -t "$current" "$minimum") || return 1
            [[ $comparison = '=' || $comparison = '>' ]];;
        rpm)
            [[ $current =~ ^[A-Za-z0-9._+~^-]+$ && $minimum =~ ^[A-Za-z0-9._+~^-]+$ ]] || return 1
            comparison=$(rpm --eval "%{lua:print(rpm.vercmp('$current','$minimum'))}") || return 1
            [[ $comparison =~ ^-?[0-9]+$ ]] && [[ $comparison -ge 0 ]];;
        brew|gentoo) versionGe "$(printf '%s' "$current" | sed 's/-r/./g' | tr '_-' '..')" "$(printf '%s' "$minimum" | tr '_-' '..')";;
    esac
}
pkgUpgrade() {
    case "$1" in
        apt) rootRun apt-get update && rootRun apt-get install --only-upgrade -y "$2";;
        # Arch does not allow partial upgrades; -Syu upgrades the whole system as well.
        pacman) rootRun pacman -Syu --needed --noconfirm "$2";;
        apk) rootRun apk update && rootRun apk upgrade "$2";;
        rpm) rootRun dnf upgrade -y "$2";;
        brew) brew update && brew upgrade "$2";;
        gentoo) rootRun emerge --sync && rootRun emerge --update --oneshot ">=app-misc/ca-certificates-$3";;
    esac
}
ensurePackage() {
    local manager=$1 package=$2 minimum=$3 current after
    current=$(pkgVersion "$manager" "$package") || { reportSkip "$package/$manager" 'No installed package was found.'; return; }
    [[ -n $current ]] || { reportSkip "$package/$manager" 'No installed package was found.'; return; }
    if pkgGe "$manager" "$current" "$minimum"; then reportSkip "$package/$manager" "Version [$current] already satisfies [$minimum]."; return; fi
    beginUpdate "$package/$manager" "$current" "$minimum" || return
    if runQuiet pkgUpgrade "$manager" "$package" "$minimum"; then
        after=$(pkgVersion "$manager" "$package")
        if [[ -n $after ]] && pkgGe "$manager" "$after" "$minimum"; then finishUpdate "$after"
        else updateFailed "$package" "Version [$after] still does not satisfy [$minimum] after the upgrade."; fi
    else updateFailed "$package"; fi
}
checkUbuntu() {
    [[ $os_id = ubuntu ]] || return
    case "$os_version" in
        22.04|24.04|26.04|26.10) ensurePackage apt ca-certificates "20260816ubuntu0.$os_version.1";;
        *) fail Ubuntu "No fix baseline is listed for distribution release [$os_version]; check the distribution announcement.";;
    esac
}
checkDebian() {
    [[ $os_id = debian ]] || return
    case "$os_version" in
        12) ensurePackage apt ca-certificates '20250419~deb12u2';;
        13) ensurePackage apt ca-certificates '20250419+deb13u1';;
        *) ensurePackage apt ca-certificates '20260816+nmu1';;
    esac
}
checkArch() { has pacman && ensurePackage pacman ca-certificates-mozilla 3.131.1-1; }
checkGentoo() { [[ $os_id = gentoo ]] && ensurePackage gentoo ca-certificates 20260816.3.125; }
checkFedora() { [[ $os_id = fedora ]] && ensurePackage rpm ca-certificates 2026.2.92_v9.0.319; }
checkChainguard() { [[ $os_id = wolfi || $os_id = chainguard ]] && ensurePackage apk ca-certificates 20260909-r3; }
checkAlpine() { [[ $os_id = alpine ]] && ensurePackage apk ca-certificates 20261020-r0; }
checkHomebrew() { has brew && ensurePackage brew ca-certificates 2026-09-25_1; }
checkNss() {
    case "$os_id" in
        debian|ubuntu) ensurePackage apt libnss3 2:3.131.1;;
        fedora) ensurePackage rpm nss 3.131.1;;
        alpine|wolfi|chainguard) ensurePackage apk nss 3.131.1;;
    esac
    has pacman && ensurePackage pacman nss 3.131.1
    has brew && ensurePackage brew nss 3.131.1
    if [[ $os_id = gentoo ]] && has pkg-config && pkg-config --exists nss; then
        ensureVersion NSS 3.131.1 getNss upgradeNss
    fi
}
getNss() { pkg-config --modversion nss; }
upgradeNss() { rootRun emerge --update --oneshot '>=dev-libs/nss-3.131.1'; }

# Only let the package manager that actually owns the executable upgrade it; do not assume brew/apt owns this program just because it is present.
upgradeOwned() {
    local tool=$1 path owner cellar formula
    path=$(command -v "$tool") || return 1
    if has readlink; then path=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path"); fi
    if has brew; then
        cellar=$(brew --cellar 2>/dev/null)
        if [[ -n $cellar && $path = "$cellar/"* ]]; then
            formula=${path#"$cellar/"}; formula=${formula%%/*}
            pkgUpgrade brew "$formula"; return
        fi
        # Claude Code and similar use casks; upgrade only the installed cask that actually contains the executable.
        cellar=$(brew --caskroom 2>/dev/null)
        if [[ -n $cellar && $path = "$cellar/"* ]]; then
            formula=${path#"$cellar/"}; formula=${formula%%/*}
            brew update && brew upgrade --cask "$formula"; return
        fi
    fi
    if has dpkg-query; then
        owner=$(dpkg-query -S "$path" 2>/dev/null | head -n 1 | sed 's/: \/.*//')
        [[ -n $owner ]] && { pkgUpgrade apt "$owner"; return; }
    fi
    if has pacman; then
        owner=$(pacman -Qoq "$path" 2>/dev/null)
        [[ -n $owner ]] && { pkgUpgrade pacman "$owner"; return; }
    fi
    if has rpm; then
        owner=$(rpm -qf --qf '%{NAME}' "$path" 2>/dev/null) && { pkgUpgrade rpm "$owner"; return; }
    fi
    if has apk; then
        owner=$(apk info --who-owns "$path" 2>/dev/null | sed -nE 's/.* is owned by (.*)-[0-9].*/\1/p')
        [[ -n $owner ]] && { pkgUpgrade apk "$owner"; return; }
    fi
    if [[ $(uname -s) = FreeBSD ]] && has pkg; then
        owner=$(pkg which -q "$path") && [[ -n $owner ]] && { rootRun pkg upgrade -y "$owner"; return; }
    fi
    echo "Could not find the original installation manager for [$tool]; upgrade it the way it was originally installed." >&2
    return 1
}

getGo() { go version 2>/dev/null | sed -nE 's/.* go([0-9][^ ]*).*/\1/p'; }
upgradeGo() { upgradeOwned go; }
checkGo() { has go && ensureVersion Go "$(targetFor go "$(getGo)")" getGo upgradeGo; }
getNode() { node --version 2>/dev/null | sed 's/^v//'; }
upgradeNode() {
    local path target
    path=$(command -v node); target=$(targetFor node "$(getNode)")
    # nvm is a shell function; source it only when the active node can be determined to belong to NVM_DIR.
    if [[ -n ${NVM_DIR:-} && $path = "$NVM_DIR/"* && -f $NVM_DIR/nvm.sh ]]; then
        . "$NVM_DIR/nvm.sh" && nvm install "$target" && nvm use "$target"
    elif [[ -n ${VOLTA_HOME:-} && $path = "$VOLTA_HOME/"* ]] && has volta; then
        volta install "node@$target"
    else upgradeOwned node; fi
}
checkNode() { has node && ensureVersion Node.js "$(targetFor node "$(getNode)")" getNode upgradeNode; }

# Python runtimes are verified against upstream branch thresholds; the interpreter list comes from collectPython, with no separate scope.
pythonTarget() {
    case "$1" in
        3.13) echo 3.13.17;;
        3.14) echo 3.14.9;;
        3.15) echo 3.15.1;;
        *) return 1;;
    esac
}
getPythonRuntime() {
    "$1" -c 'import sys
v = sys.version_info
print("%d.%d.%d" % v[:3] if v.releaselevel == "final" else "%d.%d.%d%s%d" % (v.major, v.minor, v.micro, v.releaselevel, v.serial))' 2>/dev/null
}
upgradePythonRuntime() {
    local py=$1 target=$2 prefix python_dir real=$1
    prefix=$("$py" -c 'import sys; print(sys.prefix)' 2>/dev/null) || return 1
    # A venv entry point is usually a symlink to the base interpreter; determine the install source by real path.
    if has readlink; then real=$(readlink -f "$py" 2>/dev/null || printf '%s' "$py"); fi
    # Conda environments are managed by conda; do not bypass it by switching interpreters with pip.
    if [[ -d $prefix/conda-meta ]] && has conda; then
        conda update --yes --prefix "$prefix" python; return
    fi
    # Standalone uv install: upgrade the patch release on the same branch; do not install a second copy.
    if has uv; then
        python_dir=$(uv python dir 2>/dev/null)
        if [[ -n $python_dir && $real = "$python_dir/"* ]]; then
            uv python upgrade "${target%.*}"; return
        fi
    fi
    # pyenv only installs the matching patch and leaves the user's global/local setting alone; the verification result reports the active version.
    if [[ -n ${PYENV_ROOT:-} && $real = "$PYENV_ROOT/"* ]] && has pyenv; then
        pyenv install -s "$target"; return
    fi
    upgradeOwned "$py"
}
checkPythonRuntime() {
    local py current branch minimum real seen='|'
    for py in "${python_list[@]}"; do
        # The same interpreter may have several entry points (PATH alias, venv, conda symlink); check it only once by real path.
        real=$py
        if has readlink; then real=$(readlink -f "$py" 2>/dev/null || printf '%s' "$py"); fi
        if [[ $seen = *"|$real|"* ]]; then continue; fi
        seen="$seen$real|"
        current=$(getPythonRuntime "$py") || { fail "Python ($py)" 'Could not read the interpreter version.'; continue; }
        if [[ ! $current =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            fail "Python ($py)" "Pre-release or abnormal version [$current] is not accepted as proof of a fix."; continue
        fi
        branch=${current%.*}
        minimum=$(pythonTarget "$branch") || {
            fail "Python ($py)" "No fixed version is listed for branch [$current]; use a supported branch or upgrade the original way."; continue
        }
        ensureVersion "Python ($py)" "$minimum" getPythonRuntime upgradePythonRuntime "$py" "$minimum"
    done
}

# Enumerates only Python executables on PATH, the active venv, and the current project's .venv; user directories are not walked.
collectPython() {
    local name path real seen='|' launcher
    python_list=()
    # compgen enumerates only executable names on PATH; it does not scan other projects.
    for name in python3 python pypy3 $(compgen -c | LC_ALL=C grep -E '^python[23]\.[0-9]+$' | sort -u) "${VIRTUAL_ENV:-/nonexistent}/bin/python" "$project_dir/.venv/bin/python"; do
        has "$name" || continue
        path=$(command -v "$name")
        real=$("$path" -c 'import sys; print(sys.executable)' 2>/dev/null) || continue
        [[ $seen = *"|$real|"* ]] && continue
        seen="$seen$real|"; python_list+=("$real")
    done
    for launcher in pip pip3; do
        has "$launcher" || continue
        path=$("$launcher" debug --verbose 2>/dev/null | sed -n 's/^sys.executable: //p' | head -n 1)
        [[ -x $path ]] || continue
        real=$("$path" -c 'import sys; print(sys.executable)' 2>/dev/null) || continue
        [[ $seen = *"|$real|"* ]] && continue
        seen="$seen$real|"; python_list+=("$real")
    done
}
getPythonPackage() { "$1" -c "import $2; print($2.__version__)" 2>/dev/null; }
upgradePythonPackage() {
    local py=$1 package=$2 minimum=$3 prefix
    prefix=$("$py" -c 'import sys; print(sys.prefix)' 2>/dev/null) || return 1
    # Conda environments are managed by conda; PEP 668 system environments are not forcibly broken, and --break-system-packages is not used.
    if [[ -d $prefix/conda-meta ]] && has conda; then
        conda install -y -p "$prefix" "$package>=$minimum"
    else "$py" -m pip install --upgrade "$package>=$minimum"; fi
}
checkPythonPackage() {
    local py package=$1 minimum=$2
    for py in "${python_list[@]}"; do
        "$py" -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('$package') else 1)" 2>/dev/null || {
            reportSkip "$package ($py)" 'No importable module was found; no update was performed.'; continue;
        }
        ensureVersion "$package ($py)" "$minimum" getPythonPackage upgradePythonPackage "$py" "$package" "$minimum"
    done
}
checkPip() { checkPythonPackage pip 26.2.2; }
checkCertifi() { checkPythonPackage certifi 2026.10.19; }
getUv() { uv --version 2>/dev/null | versionOf; }
upgradeUv() {
    local py path module_path
    path=$(command -v uv)
    # A uv installed through Python must be upgraded through the same interpreter.
    for py in "${python_list[@]}"; do
        module_path=$("$py" -c 'import sysconfig; print(sysconfig.get_path("scripts"))' 2>/dev/null)
        if [[ $path = "$module_path/uv" ]] && "$py" -c 'import uv' 2>/dev/null; then
            upgradePythonPackage "$py" uv 0.13.4; return
        fi
    done
    # The official self-update refuses non-official installations; fall back to the original package manager only after it fails.
    uv self update && return 0
    upgradeOwned uv
}
checkUv() { has uv && ensureVersion uv 0.13.4 getUv upgradeUv; }
getRustup() { rustup --version 2>/dev/null | versionOf; }
upgradeRustup() { rustup self update || upgradeOwned rustup; }
checkRustup() { has rustup && ensureVersion Rustup 1.29.2 getRustup upgradeRustup; }

# Rust libraries are not PATH commands; only the Cargo.lock in the current directory is handled, each version is upgraded separately, and Cargo.toml constraints are preserved.
cargoVersions() {
    awk -v wanted="$1" '/^\[\[package\]\]/{name=""}
        /^name = /{gsub(/"/,"",$3);name=$3}
        /^version = / && name==wanted {gsub(/"/,"",$3);print $3}' Cargo.lock
}
checkCargoPackage() {
    local package=$1 minimum=$2 current after bad
    [[ -f Cargo.lock ]] || return
    while IFS= read -r current; do
        [[ -n $current ]] || continue
        if versionGe "$current" "$minimum"; then reportSkip "$package/Cargo.lock" "Version [$current] already satisfies [$minimum]."; continue; fi
        cargoVersions "$package" | grep -Fxq "$current" || continue
        beginUpdate "$package/Cargo.lock" "$current" "$minimum" || continue
        if ! has cargo; then updateFailed "$package" 'A lockfile exists, but cargo was not found.'; continue; fi
        if runQuiet cargo update -p "$package@$current" --precise "$minimum"; then
            if cargoVersions "$package" | grep -Fxq "$current"; then
                updateFailed "$package" "The lockfile still contains the old branch [$current]."
            else finishUpdate "$minimum (lockfile branch $current)"; fi
        else updateFailed "$package" 'Cargo constraints or sources blocked the upgrade; adjust the upstream dependency and retry.'; fi
    done < <(cargoVersions "$package" | sort -u)
}
checkRustlsWebpki() { checkCargoPackage rustls-webpki 0.103.16; }
checkWebpkiRoots() { checkCargoPackage webpki-roots 1.0.10; }
checkWebpkiRootCerts() { checkCargoPackage webpki-root-certs 1.0.10; }

# Electron checks this project's install directory and the npm global directory; the Electron GUI is not launched.
getElectron() { node -p 'require(process.argv[1]).version' "$1/package.json" 2>/dev/null; }
upgradeElectron() {
    local package_dir=$1 scope=$2
    if [[ $scope = global ]]; then npm update -g electron
    elif [[ -f pnpm-lock.yaml ]]; then pnpm update electron
    elif [[ -f yarn.lock ]]; then
        case "$(yarn --version)" in 1.*) yarn upgrade electron;; *) yarn up electron;; esac
    else npm update electron; fi
}
checkElectron() {
    local dir global_dir
    has node || return
    dir="$project_dir/node_modules/electron"
    if [[ -f $dir/package.json ]]; then
        ensureVersion Electron "$(targetFor electron "$(getElectron "$dir")")" getElectron upgradeElectron "$dir" local
    fi
    if has npm; then
        global_dir=$(npm root -g 2>/dev/null)
        dir="$global_dir/electron"
        if [[ -n $global_dir && -f $dir/package.json && $dir != "$project_dir/node_modules/electron" ]]; then
            ensureVersion 'Electron (global)' "$(targetFor electron "$(getElectron "$dir")")" getElectron upgradeElectron "$dir" global
        fi
    fi
}

# Handles only this Action reference in the current project's workflows; floating branches and SHAs cannot be resolved offline.
getPypiActionRefs() {
    sed -nE 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'\'']?pypa\/gh-action-pypi-publish@([^ "'\''#]+).*/\2/p' "$1" | tr -d '\r'
}
getPypiActionVersion() {
    getPypiActionRefs "$1" | head -n 1 | sed 's/^v//'
}
upgradePypiActionRef() {
    local file=$1 ref=$2 escaped staged backup
    escaped=${ref//./\\.}
    staged=$(mktemp "${TMPDIR:-/tmp}/emudhra-workflow.XXXXXX") || return 1
    if ! sed -E "s#(pypa/gh-action-pypi-publish@)${escaped}([^0-9.]|\$)#\1v1.14.3\2#" "$file" >"$staged"; then
        rm -f "$staged"; return 1
    fi
    backup="$file.emudhra.$(date +%Y%m%d%H%M%S).bak"
    if ! cp -p "$file" "$backup" || ! cat "$staged" >"$file"; then
        rm -f "$staged"; return 1
    fi
    rm -f "$staged"
}
checkPypiAction() {
    local dir="$project_dir/.github/workflows" file ref displayed
    [[ -d $dir ]] || return
    for file in "$dir"/*.yml "$dir"/*.yaml; do
        [[ -f $file ]] || continue
        displayed=${file#"$project_dir"/}
        ref=$(getPypiActionRefs "$file")
        [[ -n $ref ]] || continue
        if [[ $(printf '%s\n' "$ref" | wc -l | tr -d ' ') -gt 1 ]]; then
            fail 'pypi-publish GitHub Action' "Workflow [$displayed] contains multiple references; handle it manually."; continue
        fi
        if [[ $ref =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ensureVersion "pypi-publish GitHub Action ($displayed)" 1.14.3 getPypiActionVersion upgradePypiActionRef "$file" "$ref"
        elif [[ $ref =~ ^[0-9a-f]{7,40}$ ]]; then
            reportSkip 'pypi-publish GitHub Action' "Workflow [$displayed] uses a commit SHA reference; the version cannot be resolved, so handle it manually."
        else
            reportSkip 'pypi-publish GitHub Action' "Workflow [$displayed]: reference [$ref] cannot be verified offline; switch to a fixed tag or confirm manually."
        fi
    done
}

getComposer() {
    local prefix=()
    [[ ${1:-} = global ]] && prefix=(global)
    composer "${prefix[@]}" show composer/ca-bundle --format=json 2>/dev/null | php -r '$j=json_decode(stream_get_contents(STDIN),true); if(isset($j["versions"][0])) echo ltrim($j["versions"][0],"v");'
}
upgradeComposer() {
    local prefix=()
    [[ ${1:-} = global ]] && prefix=(global)
    composer "${prefix[@]}" update composer/ca-bundle --with-dependencies --no-interaction
}
checkComposer() {
    local current
    if [[ -f composer.lock ]] && grep -q '"composer/ca-bundle"' composer.lock; then
        if has composer && has php; then
            ensureVersion 'Composer ca-bundle' "$(targetFor composer "$(getComposer)")" getComposer upgradeComposer local
        else fail 'Composer ca-bundle' 'The lockfile contains this dependency, but composer/php is not on PATH.'; fi
    fi
    if has composer && has php; then
        current=$(getComposer global)
        [[ -n $current ]] && ensureVersion 'Composer ca-bundle (global)' "$(targetFor composer "$current")" getComposer upgradeComposer global
    fi
}
getCastore() { sed -nE 's/.*"castore"[[:space:]]*:[[:space:]]*\{:hex,[[:space:]]*:castore,[[:space:]]*"([^"]+)".*/\1/p' mix.lock; }
upgradeCastore() { mix deps.update castore; }
checkCastore() {
    [[ -f mix.lock ]] || return
    grep -q '"castore"' mix.lock || return
    has mix || { fail castore 'The dependency exists, but mix was not found.'; return; }
    ensureVersion castore 1.0.22 getCastore upgradeCastore
}
getPerlCa() { perl -MMozilla::CA -e 'print $Mozilla::CA::VERSION' 2>/dev/null; }
upgradePerlCa() {
    if has cpanm; then cpanm 'Mozilla::CA~>=20261020'
    elif has cpan; then PERL_MM_USE_DEFAULT=1 cpan -i Mozilla::CA
    else echo 'cpanm/cpan was not found.' >&2; return 1; fi
}
checkPerlCa() { has perl && getPerlCa >/dev/null && ensureVersion 'Perl Mozilla::CA' 20261020 getPerlCa upgradePerlCa; }

# A CA bundle is overwritten only when it is a recognizable curl Mozilla export, so corporate custom trust stores are not replaced.
bundleDate() {
    LC_ALL=C awk '/^## Certificate data from Mozilla as of:/ {
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",m," ");
        for(i=1;i<=12;i++)if($(NF-4)==m[i])printf "%04d.%02d.%02d\n",$(NF-1),i,$(NF-3)
    }' "$1"
}
upgradeBundle() {
    local file=$1 expected actual staged
    has curl || { echo 'curl was not found.' >&2; return 1; }
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' https://curl.se/ca/cacert.pem -o "$temp_dir/cacert.pem" || return 1
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' https://curl.se/ca/cacert.pem.sha256 -o "$temp_dir/cacert.sha256" || return 1
    expected=$(awk '{print $1;exit}' "$temp_dir/cacert.sha256")
    if has sha256sum; then actual=$(sha256sum "$temp_dir/cacert.pem" | awk '{print $1}')
    elif has shasum; then actual=$(shasum -a 256 "$temp_dir/cacert.pem" | awk '{print $1}')
    else echo 'sha256sum or shasum is required.' >&2; return 1; fi
    [[ $expected =~ ^[a-fA-F0-9]{64}$ && $expected = "$actual" ]] || { echo 'CA bundle SHA256 verification failed.' >&2; return 1; }
    versionGe "$(bundleDate "$temp_dir/cacert.pem")" 2026.10.20 || return 1
    # Stage in the target directory and replace atomically; keep the original file and its permissions first.
    staged=$(mktemp "${file}.emudhra.XXXXXX") || return 1
    cp -p "$file" "$file.emudhra.$(date +%Y%m%d%H%M%S).bak" &&
        cp -p "$file" "$staged" && cat "$temp_dir/cacert.pem" >"$staged" && mv -f "$staged" "$file"
    local rc=$?; [[ -f $staged ]] && rm -f "$staged"; return "$rc"
}
checkCurlBundle() {
    local file current seen='|' py owned managed
    for file in "${CURL_CA_BUNDLE:-}" "${SSL_CERT_FILE:-}" "${REQUESTS_CA_BUNDLE:-}" "$project_dir/cacert.pem" "$project_dir/curl-ca-bundle.crt"; do
        [[ -n $file && -f $file ]] || continue
        [[ $seen = *"|$file|"* ]] && continue; seen="$seen$file|"
        managed=0
        for py in "${python_list[@]}"; do
            owned=$("$py" -c 'import certifi; print(certifi.where())' 2>/dev/null)
            if [[ -n $owned && $file -ef $owned ]]; then managed=1; break; fi
        done
        [[ $managed = 1 ]] && continue
        current=$(bundleDate "$file")
        if [[ -z $current ]]; then
            # Files maintained by system packages are covered by the system handlers; versions of explicitly custom files cannot be inferred.
            case "$file" in /etc/ssl/cert.pem|/etc/ssl/certs/ca-certificates.crt|/etc/pki/*) continue;; esac
            fail "CA bundle ($file)" 'Could not recognize the curl export date; the custom CA bundle was not overwritten.'; continue
        fi
        ensureVersion "curl CA bundle ($file)" 2026.10.20 bundleDate upgradeBundle "$file"
    done
}

# Git commits cannot be compared by string order. Ancestry is checked only when the current directory is exactly the corresponding repository.
checkCfssl() {
    has git && [[ -d .git || -f .git ]] || return
    local remote current marker=trust-store-2026.10.1
    remote=$(git remote get-url origin 2>/dev/null)
    [[ $remote = *cloudflare/cfssl_trust* ]] || return
    if git merge-base --is-ancestor "$marker" HEAD 2>/dev/null; then reportSkip 'CFSSL trust store' "Already contains [$marker]."; return; fi
    current=$(git describe --tags --match 'trust-store-*' --abbrev=0 2>/dev/null)
    [[ -n $current ]] || { fail 'CFSSL trust store' 'Could not determine the version from local tags; run git fetch --tags and retry.'; return; }
    if versionGe "${current#trust-store-}" 2026.10.1; then reportSkip 'CFSSL trust store' "Version [$current] already satisfies the requirement."; return; fi
    beginUpdate 'CFSSL trust store' "$current" 2026.10.1 || return
    if [[ -n $(git status --porcelain) ]]; then updateFailed CFSSL 'The repository has uncommitted changes.'; return; fi
    if runQuiet git fetch origin tag "$marker" && runQuiet git merge --ff-only "$marker" && runQuiet git merge-base --is-ancestor "$marker" HEAD; then
        finishUpdate "$marker"
    else updateFailed CFSSL 'Could not fast-forward to the fixed version; check the repository branch and remote.'; fi
}
checkGuix() {
    has guix || return
    # The Guix version number does not represent the channel commit; without local history the version number must not be treated as proof of the fix.
    local commit marker=7608a9954a7ba0a9ce756bf3135dc0ba51a40af9
    commit=$(getGuixCommit)
    if [[ $commit = "$marker" ]]; then reportSkip Guix "The channel already contains fix commit [$marker]."; return; fi
    if [[ -d .git ]] && git cat-file -e "$commit^{commit}" 2>/dev/null && git cat-file -e "$marker^{commit}" 2>/dev/null; then
        if git merge-base --is-ancestor "$marker" "$commit"; then reportSkip Guix 'The channel already contains the fix commit.'; return; fi
        beginUpdate Guix "$commit" "$marker" || return
        if runQuiet guix pull && runQuiet guix upgrade '^(nss|nss-certs|ca-certificates)$'; then
            # The new guix lives in the current user's current profile; verification succeeds only if the original PATH also points to it.
            commit=$(getGuixCommit)
            if git merge-base --is-ancestor "$marker" "$commit" 2>/dev/null; then finishUpdate "$commit"
            else updateFailed Guix 'The channel commit could not be verified in local history after the update.'; fi
        else updateFailed Guix; fi
    else fail Guix 'Run this in the current repository with complete Guix history so channel commits can be compared; the version was not guessed.'; fi
}
getGuixCommit() {
    # With multiple channels, the channel named guix must be selected; do not just take the first commit.
    guix describe --format=channels 2>/dev/null | awk '
        /\(name / {selected=($0 ~ /\047guix\)/)}
        selected && /\(commit "/ {split($0,a,"\""); print a[2]; exit}'
}

# Pending items keep their own entry points; once upstream publishes a fix, only the corresponding function and version need to be filled in.
checkBottlerocket() { reportSkip Bottlerocket 'Still pending in the patch table; no fixed version is configured yet.'; }
checkErlangCertifi() { reportSkip 'Erlang certifi' 'Still pending in the patch table; no fixed version is configured yet.'; }

# Devuan 5/6 use the Debian 12/13 package versions respectively; do not concatenate the Devuan major version with a deb suffix.
checkDevuan() {
    [[ $os_id = devuan ]] || return
    case "$os_version" in
        5|5.*) ensurePackage apt ca-certificates '20250419~deb12u2';;
        6|6.*) ensurePackage apt ca-certificates '20250419+deb13u1';;
        *) fail Devuan "No mapping from distribution release [$os_version] to Debian is configured.";;
    esac
}
freebsdTarget() {
    case "$1" in
        15.1-RELEASE*) echo 15.1.6;;
        14.5-RELEASE*) echo 14.5.3;;
        14.4-RELEASE*) echo 14.4.12;;
        *) return 1;;
    esac
}
getFreebsdCaroot() {
    # caroot belongs to the installed userland; the running kernel's uname -r must not be used instead.
    local current
    current=$(freebsd-version -u) || return 1
    [[ $current =~ ^([0-9]+\.[0-9]+)-RELEASE(-p([0-9]+))?$ ]] || return 1
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-0}"
}
upgradeFreebsdCaroot() {
    # The official advisory distinguishes pkgbase from traditional distribution sets; the upgrade stays on the current RELEASE branch and does not reboot.
    if has pkg && pkg info -e FreeBSD-runtime >/dev/null 2>&1; then
        rootRun pkg upgrade -y -r FreeBSD-base
    elif has freebsd-update; then
        rootRun freebsd-update fetch && rootRun freebsd-update install
    else echo 'Neither pkgbase nor freebsd-update was found; for source installations, update according to FreeBSD-SA-26:73.' >&2; return 1; fi
}
checkFreebsdCaroot() {
    [[ $(uname -s) = FreeBSD ]] || return
    local current minimum
    current=$(freebsd-version -u) || { fail 'FreeBSD caroot' 'Could not read the userland version.'; return; }
    minimum=$(freebsdTarget "$current") || { fail 'FreeBSD caroot' "The current branch [$current] is not in the verified RELEASE patch table."; return; }
    ensureVersion 'FreeBSD caroot' "$minimum" getFreebsdCaroot upgradeFreebsdCaroot
}
getFreebsdNss() { pkg query '%v' ca_root_nss; }
upgradeFreebsdNss() { rootRun pkg update && rootRun pkg upgrade -y ca_root_nss; }
checkFreebsd() {
    [[ $(uname -s) = FreeBSD ]] && has pkg || return
    pkg info -e ca_root_nss >/dev/null 2>&1 || { reportSkip 'FreeBSD ca_root_nss' 'This package is not installed.'; return; }
    local current after comparison
    current=$(getFreebsdNss) || { fail ca_root_nss 'Could not query the package version.'; return; }
    comparison=$(pkg version -t "$current" 1.131.1) || { fail ca_root_nss 'Could not compare the package versions.'; return; }
    if [[ $comparison = '=' || $comparison = '>' ]]; then reportSkip ca_root_nss "Version [$current] already satisfies [1.131.1]."; return; fi
    beginUpdate ca_root_nss "$current" 1.131.1 || return
    if runQuiet upgradeFreebsdNss; then
        after=$(getFreebsdNss)
        comparison=$(pkg version -t "$after" 1.131.1)
        if [[ $comparison = '=' || $comparison = '>' ]]; then finishUpdate "$after"
        else updateFailed ca_root_nss "[$after] still does not satisfy [1.131.1] after the upgrade."; fi
    else updateFailed ca_root_nss; fi
}

# Flatpak branches 25.08/26.08 are not patch versions; the full version actually deployed must be read.
getFreedesktop() {
    local scope=$1 ref=$2 location file value
    value=$(LC_ALL=C flatpak info "$scope" "$ref" | sed -nE 's/^[[:space:]]*Version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p')
    if [[ -n $value ]]; then echo "$value"; return; fi
    location=$(flatpak info "$scope" --show-location "$ref") || return 1
    for file in "$location/files/etc/os-release" "$location/files/lib/os-release"; do
        [[ -r $file ]] || continue
        value=$(sed -nE 's/^(VERSION|VERSION_ID|BUILD_ID)="?([0-9]+\.[0-9]+\.[0-9]+)"?$/\2/p' "$file" | head -n 1)
        if [[ -n $value ]]; then echo "$value"; return; fi
    done
    echo 'Could not read the full Freedesktop patch version; the Flatpak branch number was not treated as proof of the fix.' >&2; return 1
}
upgradeFreedesktop() { flatpak update --noninteractive "$1" "$2"; }
checkFreedesktop() {
    has flatpak || return
    local scope ref branch minimum refs
    for scope in --system --user; do
        refs=$(flatpak list "$scope" --runtime --columns=ref) || { fail 'Freedesktop SDK' "Could not list [$scope] runtimes."; continue; }
        while IFS= read -r ref; do
            case "$ref" in org.freedesktop.Sdk/*|org.freedesktop.Platform/*) ;; *) continue;; esac
            branch=${ref##*/}
            case "$branch" in 25.08) minimum=25.08.19;; 26.08) minimum=26.08.3;;
                *) fail 'Freedesktop SDK' "No fix baseline is listed for the branch of runtime [$ref]."; continue;; esac
            ensureVersion "Freedesktop ($scope $ref)" "$minimum" getFreedesktop upgradeFreedesktop "$scope" "$ref"
        done <<< "$refs"
    done
}

# The OmniOS package version is fixed at 5.11; the NSS version is in the installed package's pkg.description.
# The DESC in the official build/ca-bundle/build.sh contains mozilla-nss $NSSVER; 5.11 must not be compared with NSS.
getOmniosBundle() {
    local description version
    description=$(LC_ALL=C pkg contents -H -t set -a name=pkg.description -o value web/ca-bundle) || return 1
    version=$(printf '%s\n' "$description" | sed -nE 's/.*mozilla-nss (3\.[0-9]+(\.[0-9]+)*) source.*/\1/p')
    [[ -n $version ]] || { echo "Could not read the NSS version of web/ca-bundle: $description" >&2; return 1; }
    echo "$version"
}
upgradeOmnios() { rootRun pkg update web/ca-bundle; }
checkOmnios() {
    [[ $(uname -s) = SunOS ]] && [[ -r /etc/release ]] && grep -qi OmniOS /etc/release || return
    has pkg || { fail 'OmniOS web/ca-bundle' 'IPS pkg was not found.'; return; }
    pkg list -H web/ca-bundle >/dev/null 2>&1 || { reportSkip 'OmniOS web/ca-bundle' 'This package is not installed.'; return; }
    # Minimum NSS versions for the CA bundle corresponding to r151054by / r151056ay / r151058y.
    ensureVersion 'OmniOS web/ca-bundle (r151054by/r151056ay/r151058y)' 3.131.1 getOmniosBundle upgradeOmnios
}

# OpenBSD's cert.pem belongs to base; releases are updated by syspatch errata, and -current has no patch to verify.
openbsdErratum() {
    case "$1" in
        7.9) echo 040_dbupdate;;
        8.0) echo 005_dbupdate;;
        *) return 1;;
    esac
}
checkOpenbsd() {
    [[ $(uname -s) = OpenBSD ]] || return
    local release erratum full kernel
    release=$(uname -r 2>/dev/null)
    full=$(uname -v 2>/dev/null)
    kernel=$(sysctl -n kern.version 2>/dev/null)
    if [[ $release = *-current || $full = *-current || $kernel = *-current ]]; then
        fail OpenBSD 'This is -current, so there is no errata to verify; follow base updates and confirm cert.pem manually.'; return
    fi
    erratum=$(openbsdErratum "$release") || {
        fail OpenBSD "No fix patch is listed for release [$release]; this version may be EOL."; return
    }
    has syspatch || { fail OpenBSD 'syspatch was not found; base patches cannot be verified.'; return; }
    if syspatch -l 2>/dev/null | grep -Fxq "$erratum"; then
        reportSkip OpenBSD "Base patch [$erratum] is already installed."; return
    fi
    reported=$((reported + 1))
    if [[ $check_only = 1 ]]; then
        printf 'Pending upgrade [OpenBSD %s]: missing base patch [%s]\n' "$release" "$erratum"
        pending=$((pending + 1)); return
    fi
    active_update=1; update_log="$temp_dir/update.log"; : >"$update_log"
    printf 'Found [OpenBSD %s], missing base patch [%s], running syspatch...\n' "$release" "$erratum"
    # syspatch applies all pending base patches at once; it cannot install only this one.
    if runQuiet rootRun syspatch && syspatch -l 2>/dev/null | grep -Fxq "$erratum"; then
        finishUpdate "$erratum"
    else
        updateFailed OpenBSD 'syspatch did not install the specified patch; check errata and the privilege escalation method (sudo/doas).'
    fi
}

normalizeJava() {
    local version=${1%%+*}
    if [[ $version =~ ^1\.8\.0_([0-9]+)(-b[0-9]+)?$ ]]; then echo "8.0.${BASH_REMATCH[1]}"
    else echo "$version"; fi
}
javaTarget() {
    case "${1%%.*}" in
        8) echo 8.0.511;; 11) echo 11.0.33.0.2;; 17) echo 17.0.21.0.2;;
        21) echo 21.0.13.0.2;; 25) echo 25.0.5.0.2;; 27) echo 27.0.1.0.2;;
        *) return 1;;
    esac
}
getJava() {
    local details version
    details=$(java -XshowSettings:properties -version 2>&1) || { printf '%s\n' "$details" >&2; return 1; }
    version=$(printf '%s\n' "$details" | sed -n 's/^[[:space:]]*java.runtime.version = //p' | head -n 1)
    [[ -n $version ]] || version=$(printf '%s\n' "$details" | sed -n 's/^[[:space:]]*java.version = //p' | head -n 1)
    [[ -n $version ]] || return 1
    normalizeJava "$version"
}
upgradeJava() {
    local java_dir
    java_dir=$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^[[:space:]]*java.home = //p' | head -n 1)
    [[ -x $java_dir/bin/java ]] || { echo 'Could not locate the installation directory of the active Java.' >&2; return 1; }
    upgradeOwned "$java_dir/bin/java"
}
checkJava() {
    has java || return
    local current minimum
    current=$(getJava) || { fail Java 'Could not read the full runtime version of the active Java.'; return; }
    minimum=$(javaTarget "$current") || { fail Java "No fixed version is listed for branch [$current]; use a branch supported by the original vendor."; return; }
    ensureVersion Java "$minimum" getJava upgradeJava
}

getPixi() { pixi --version | versionOf; }
upgradePixi() { pixi self-update || upgradeOwned pixi; }
checkPixi() { has pixi && ensureVersion pixi 0.82.1 getPixi upgradePixi; }
getClaude() { claude --version | versionOf; }
upgradeClaude() {
    # For some manager installations, claude update succeeds but only advises using the manager; the version still needs re-checking.
    if claude update && versionGe "$(getClaude)" 2.1.303; then return; fi
    upgradeOwned claude
}
checkClaude() { has claude && ensureVersion 'Claude Code' 2.1.303 getClaude upgradeClaude; }
getMise() { mise --version | versionOf; }
upgradeMise() { mise self-update --yes --no-plugins || upgradeOwned mise; }
checkMise() { has mise && ensureVersion mise 2026.10.17 getMise upgradeMise; }
getDeno() { deno --version | versionOf; }
upgradeDeno() { deno upgrade || upgradeOwned deno; }
checkDeno() { has deno && ensureVersion Deno 2.9.8 getDeno upgradeDeno; }

getBun() { bun --version 2>/dev/null | versionOf; }
upgradeBun() {
    local path cellar
    path=$(command -v bun)
    # Homebrew installations are left to the original manager so self-update does not overwrite the brew record.
    if has brew; then
        cellar=$(brew --cellar 2>/dev/null)
        if [[ -n $cellar && $path = "$cellar/"* ]]; then brew update && brew upgrade bun; return; fi
    fi
    # canary versions are not accepted as proof of a fix; switch back to stable before verifying during self-update.
    bun upgrade --stable && return 0
    upgradeOwned bun
}
checkBun() { has bun && ensureVersion Bun 1.4.4 getBun upgradeBun; }

getConda() { conda --version 2>/dev/null | versionOf; }
upgradeConda() {
    # Official update command; keep the user's existing channel configuration and do not add a default channel.
    conda update --name base --yes conda
}
checkConda() { has conda && ensureVersion Conda 26.9.4 getConda upgradeConda; }

# ArgoCD CLI and in-cluster server versions are handled separately: only the local CLI is changed safely; the server is only reported.
getArgocd() { argocd version --client --short 2>/dev/null | versionOf; }
upgradeArgocd() { upgradeOwned argocd; }
checkArgocdServer() {
    local image server
    has kubectl || { reportSkip 'ArgoCD server' 'kubectl was not found; verify the server version on the cluster side according to the deployment method.'; return; }
    image=$(kubectl -n argocd get deployment argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    if [[ -z $image ]]; then
        reportSkip 'ArgoCD server' 'Could not read the argocd-server deployment; the server version cannot be verified.'; return
    fi
    if [[ $image =~ :v?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then server=${BASH_REMATCH[1]}
    else reportSkip 'ArgoCD server' "Image [$image] does not use a comparable version tag; confirm manually."; return; fi
    if versionGe "$server" 3.3.18; then reportSkip 'ArgoCD server' "Image [$image] already satisfies the requirement."
    else fail 'ArgoCD server' "Image [$image] is below 3.3.18; upgrade it through Helm/deployment manifests, the script does not modify the cluster automatically."; fi
}
checkArgocd() {
    has argocd && ensureVersion 'ArgoCD CLI' 3.3.18 getArgocd upgradeArgocd
    has kubectl && checkArgocdServer
}

# Docker Desktop is a separate application; the docker Engine/CLI version cannot stand in for the Desktop version.
getDockerDesktop() {
    local version
    case "$(uname -s)" in
        Darwin)
            [[ -r /Applications/Docker.app/Contents/Info.plist ]] || return 1
            has defaults || return 1
            version=$(defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null) || return 1
            ;;
        Linux)
            # Only Desktop provides the docker desktop subcommand; the regular Docker CLI does not.
            has docker || return 1
            version=$(docker desktop version 2>/dev/null | versionOf) || return 1
            ;;
        *) return 1;;
    esac
    [[ -n $version ]] || return 1
    printf '%s\n' "$version"
}
upgradeDockerDesktop() {
    case "$(uname -s)" in
        Darwin)
            if has brew; then brew update && brew upgrade --cask docker; return; fi;;
        Linux)
            if has apt-get; then rootRun apt-get install --only-upgrade -y docker-desktop; return
            elif has dnf; then rootRun dnf upgrade -y docker-desktop; return
            elif has pacman; then rootRun pacman -Syu --needed --noconfirm docker-desktop; return
            fi;;
    esac
    # Do not restart the user's engine on our own; when auto-update is not possible, hand back to the in-app update.
    echo 'Use the Docker Desktop in-app update or the original installer; Docker Desktop must be restarted after the upgrade for it to take effect.' >&2
    return 1
}
checkDockerDesktop() {
    [[ $(uname -s) = Darwin || $(uname -s) = Linux ]] || return
    getDockerDesktop >/dev/null 2>&1 || return
    local before=${updated:-0}
    ensureVersion 'Docker Desktop' 4.96.2 getDockerDesktop upgradeDockerDesktop
    [[ ${updated:-0} != "$before" ]] && printf 'Note: Docker Desktop must be restarted before the new version is used.\n'
}

# Handlers that produce no result explain the reason at the actual check entry point; not installed and not applicable are not conflated with fixed.
invokeCheck() {
    local handler=$1 before=${reported:-0} label reason
    active_update=0
    "$handler"
    [[ ${reported:-0} != "$before" ]] && return
    case "$handler" in
        checkUbuntu|checkDebian|checkDevuan|checkGentoo|checkFedora|checkChainguard|checkAlpine)
            label=${handler#check}; reason="This does not apply on the current distribution [${os_id:-unknown}].";;
        checkArch) label='Arch CA package'; reason='No matching installation managed by pacman was found.';;
        checkHomebrew) label='Homebrew CA package'; reason='brew was not found.';;
        checkNss) label=NSS; reason='This environment has no recognizable standalone NSS installation entry point.';;
        checkGuix) label=Guix; reason='guix was not found on PATH.';;
        checkCurlBundle) label='curl CA bundle'; reason='No separately handled certificate file was found; files managed by the system/certifi are checked by the corresponding item.';;
        checkCfssl) label='CFSSL trust store'; reason='The current directory is not a recognizable cloudflare/cfssl_trust Git repository, or git was not found.';;
        checkGo) label=Go; reason='go was not found on PATH.';;
        checkNode) label=Node.js; reason='node was not found on PATH.';;
        checkPip|checkCertifi) label=${handler#check}; reason='No usable Python/module environment was found in the checked scope.';;
        checkUv) label=uv; reason='uv was not found on PATH.';;
        checkRustup) label=Rustup; reason='rustup was not found on PATH.';;
        checkRustlsWebpki|checkWebpkiRoots|checkWebpkiRootCerts)
            label=${handler#check}; reason='The current directory has no recognizable Cargo.lock containing this library.';;
        checkElectron) label=Electron; reason='No recognizable installation record was found in the current directory or the queryable npm global directory, or node was not found.';;
        checkComposer) label='Composer ca-bundle'; reason='No recognizable installation record was found in the current project or the queryable Composer global installation.';;
        checkCastore) label='Elixir castore'; reason='The current directory has no mix.lock containing castore.';;
        checkPerlCa) label='Perl Mozilla::CA'; reason='Perl was not found, or the active Perl cannot import Mozilla::CA.';;
        checkFreebsdCaroot|checkFreebsd) label=${handler#check}; reason='This system is not FreeBSD, or the corresponding package manager was not found.';;
        checkFreedesktop) label='Freedesktop SDK'; reason='Flatpak was not found, or no Freedesktop SDK/Platform runtime is installed.';;
        checkOmnios) label='OmniOS web/ca-bundle'; reason='This system is not OmniOS.';;
        checkOpenbsd) label='OpenBSD cert.pem'; reason='This system is not OpenBSD.';;
        checkJava) label=Java; reason='java was not found on PATH.';;
        checkPixi) label=pixi; reason='pixi was not found on PATH.';;
        checkClaude) label='Claude Code'; reason='claude was not found on PATH.';;
        checkMise) label=mise; reason='mise was not found on PATH.';;
        checkDeno) label=Deno; reason='deno was not found on PATH.';;
        checkBun) label=Bun; reason='bun was not found on PATH.';;
        checkConda) label=Conda; reason='conda was not found on PATH.';;
        checkArgocd) label='ArgoCD CLI'; reason='argocd was not found on PATH.';;
        checkDockerDesktop) label='Docker Desktop'; reason='No recognizable Docker Desktop installation was found on this system or install path.';;
        checkPypiAction) label='pypi-publish GitHub Action'; reason='The workflows of the current project contain no reference to this Action.';;
        checkPythonRuntime) label='Python runtime'; reason='No usable Python interpreter was found in the checked scope.';;
        *) label=$handler; reason='No applicable installation was found.';;
    esac
    reportSkip "$label" "$reason"
}

main() {
    printf 'eMudhra fix script | Finalized at: %s\n' "$SCRIPT_FINALIZED_AT"
    check_only=0; errors=0; pending=0; updated=0; skipped=0; reported=0; active_update=0; project_dir=$PWD
    case "${1:-}" in
        --check) check_only=1;;
        --help|-h) printf 'Usage: bash emudhrafix.sh [--check]\nChecks system tools and the runtime current directory; --check only detects, no upgrade.\n'; return 0;;
        '') ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; return 2;;
    esac
    [[ $# -le 1 ]] || return 2
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/emudhra.XXXXXX") || return 2
    trap 'rm -rf -- "$temp_dir"' EXIT
    os_id=; os_version=
    if [[ -r /etc/os-release ]]; then
        os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
        os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
    fi
    printf 'Scope: system tools and current directory [%s]. Detecting Python environments, please wait...\n' "$project_dir"
    [[ $check_only = 1 ]] && printf '[Check mode]\n'
    collectPython
    printf 'Environment detection complete; checking items in patch table order...\n'
    invokeCheck checkUbuntu; 
    invokeCheck checkDebian; 
    invokeCheck checkDevuan;
    invokeCheck checkArch; 
    invokeCheck checkGentoo; 
    invokeCheck checkFedora;
    invokeCheck checkFreebsdCaroot; 
    invokeCheck checkFreebsd; 
    invokeCheck checkFreedesktop;
    invokeCheck checkChainguard; 
    invokeCheck checkAlpine; 
    invokeCheck checkGuix; 
    invokeCheck checkOmnios;
    invokeCheck checkOpenbsd; 
    invokeCheck checkBottlerocket;
    invokeCheck checkNss; 
    invokeCheck checkCurlBundle; 
    invokeCheck checkCfssl;
    invokeCheck checkHomebrew; 
    invokeCheck checkGo; 
    invokeCheck checkJava; 
    invokeCheck checkNode;
    invokeCheck checkPythonRuntime; 
    invokeCheck checkCertifi; 
    invokeCheck checkPip;
    invokeCheck checkUv; 
    invokeCheck checkPixi;
    invokeCheck checkRustlsWebpki; 
    invokeCheck checkWebpkiRoots; 
    invokeCheck checkWebpkiRootCerts; 
    invokeCheck checkRustup;
    invokeCheck checkElectron; 
    invokeCheck checkBun; 
    invokeCheck checkClaude;
    invokeCheck checkArgocd; 
    invokeCheck checkDockerDesktop;
    invokeCheck checkComposer; 
    invokeCheck checkCastore; 
    invokeCheck checkErlangCertifi;
    invokeCheck checkMise; 
    invokeCheck checkPypiAction; 
    invokeCheck checkPerlCa;
    invokeCheck checkDeno; 
    invokeCheck checkConda;
    printf 'Done: %s upgraded; %s pending; %s skipped; %s errors/unverified.\n' "$updated" "$pending" "$skipped" "$errors"
    [[ $errors = 0 && $pending = 0 ]]
}

if [[ ${BASH_SOURCE[0]} = "$0" ]]; then main "$@"; fi
