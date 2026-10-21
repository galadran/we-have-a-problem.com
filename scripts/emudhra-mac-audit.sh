#!/bin/bash -p
# Read-only eMudhra trust-store audit. See scripts/README.md.
# Embedded public data: roots.json and impacted-intermediates.json at bb7c2a87c5f9157ad83dd8ac32ae90a7e3205274.
EM_PLATFORM=mac
# shellcheck shell=bash
# Bash 3.2 compatible; uses native OpenSSL/LibreSSL. No Python or sidecars required.
set -u
set -o pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH LC_ALL=C LANG=C
unset BASH_ENV ENV CDPATH OPENSSL_CONF OPENSSL_MODULES OPENSSL_ENGINES JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS
unset LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
umask 077
EM_WORK='' EM_CHILD='' EM_WATCH='' EM_BAD=0 EM_AFFECTED=0 EM_CHECKED=0 EM_REASON=''
EM_COLOR=auto EM_PROBE=0 EM_EXPLICIT=0
EM_BUNDLES=() EM_JAVA=() EM_SEEN=()

em_log() {
    local tag=$1 message=$2 code=''
    case "$tag" in PASS) code=32;; ERROR) code=31;; WARN) code=33;; INFO) code=36;; esac
    if [[ $EM_COLOR == always || ( $EM_COLOR == auto && -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ) ]]; then
        printf '\033[%sm[%s]\033[0m %s\n' "$code" "$tag" "$message"
    else
        printf '[%s] %s\n' "$tag" "$message"
    fi
}

em_error() { EM_BAD=$((EM_BAD + 1)); em_log ERROR "$1"; }

em_reason() { EM_REASON=$1; return 2; }
# shellcheck disable=SC2329 # EXIT/signal trap callback.

em_cleanup() {
    [[ -z $EM_CHILD ]] || kill "$EM_CHILD" 2>/dev/null || :
    [[ -z $EM_WATCH ]] || kill "$EM_WATCH" 2>/dev/null || :
    case "$EM_WORK" in /tmp/emudhra.*) rm -rf -- "$EM_WORK";; esac
}

em_out() {
    local destination=$1 limit=$2 rc
    shift 2
    /usr/bin/env -i PATH="$PATH" LC_ALL=C LANG=C HOME="$EM_HOME" OPENSSL_CONF=/dev/null "$@" > "$destination" 2> "$EM_WORK/command.err" &
    EM_CHILD=$!
    # A separate monitor shell waits using its builtin read timeout, so cancelling
    # it cannot leave a long-running sleep process behind.
    (
        exec 9<> "$EM_WORK/clock"
        if ! IFS= read -r -t "$limit" -u 9 _; then
            kill -TERM "$EM_CHILD" 2>/dev/null || :
            IFS= read -r -t 1 -u 9 _ || :
            kill -KILL "$EM_CHILD" 2>/dev/null || :
        fi
    ) >/dev/null 2>&1 &
    EM_WATCH=$!
    if wait "$EM_CHILD"; then rc=0; else rc=$?; fi
    EM_CHILD=''
    kill "$EM_WATCH" 2>/dev/null || :
    wait "$EM_WATCH" 2>/dev/null || :
    EM_WATCH=''
    if [[ $rc -ne 0 ]]; then
        EM_REASON="$1 exited $rc: $(head -c 400 "$EM_WORK/command.err")"
    fi
    return "$rc"
}

em_run() { em_out "$EM_WORK/command.out" "$@"; }

em_b64() {
    awk 'NR==1 {next} /^-----END / {exit} {
      if($0 ~ /[^A-Za-z0-9+\/= \t\r]/) exit 2
      gsub(/[ \t\r]/, ""); printf "%s", $0
    }' "$1" > "$EM_WORK/base64" || return 2
    em_out "$2" 10 openssl enc -base64 -d -A -in "$EM_WORK/base64" || return 2
    em_out "$EM_WORK/base64-again" 10 openssl enc -base64 -A -in "$2" || return 2
    if [[ ! -s $2 ]] || ! cmp -s "$EM_WORK/base64" "$EM_WORK/base64-again"; then em_reason 'Invalid/noncanonical Base64'; return 2; fi
}

em_cert() {
    local block=$1 kind=$2
    em_b64 "$block" "$EM_WORK/raw.der" || return 2
    if [[ $kind == TRUSTED ]]; then
        em_out "$EM_WORK/roundtrip.pem" 10 openssl x509 -in "$block" -outform PEM -trustout || return 2
        em_b64 "$EM_WORK/roundtrip.pem" "$EM_WORK/roundtrip.der" || return 2
        cmp -s "$EM_WORK/raw.der" "$EM_WORK/roundtrip.der" || { em_reason 'Trusted certificate trailing/noncanonical data'; return 2; }
        em_out "$EM_WORK/cert.der" 10 openssl x509 -in "$block" -outform DER || return 2
    else
        em_out "$EM_WORK/cert.der" 10 openssl x509 -inform DER -in "$EM_WORK/raw.der" -outform DER || return 2
        cmp -s "$EM_WORK/raw.der" "$EM_WORK/cert.der" || { em_reason 'Certificate trailing/noncanonical DER data'; return 2; }
    fi
    em_out "$EM_WORK/hash" 10 openssl dgst -sha256 "$EM_WORK/cert.der" || return 2
    EM_FP=$(awk '{print toupper($NF)}' "$EM_WORK/hash")
    [[ $EM_FP =~ ^[A-F0-9]{64}$ ]] || { em_reason 'Invalid SHA-256 output'; return 2; }
}

em_parse() {
    local input=$1 output=$2 total type offset count kind
    EM_COUNT=0 EM_MATCHES=0
    # Shell variables never contain raw bundle bytes. dd copies exact byte spans.
    tr -d '\000' < "$input" > "$EM_WORK/nonul" || return 2
    cmp -s "$input" "$EM_WORK/nonul" || { em_reason 'NUL-containing PEM bundle is unsupported'; return 2; }
    total=$(wc -c < "$input")
    awk -v total="$total" '
      BEGIN {pos=0; cursor=0; inside=0; certs=0; bad=0}
      { line=$0; sub(/\r$/, "", line)
        if(line ~ /^-----BEGIN (CERTIFICATE|TRUSTED CERTIFICATE)-----[ \t]*$/) {
          if(inside) {bad=1; exit 2}
          if(pos>cursor) print "G",cursor,pos-cursor,"NONE"
          start=pos; inside=1; kind=(line ~ /TRUSTED/ ? "TRUSTED" : "PLAIN")
        } else if(line ~ /-----BEGIN .*CERTIFICATE-----/) {bad=1; exit 2}
        if(line ~ /^-----END (CERTIFICATE|TRUSTED CERTIFICATE)-----[ \t]*$/) {
          if(!inside || (kind=="TRUSTED") != (line ~ /TRUSTED/)) {bad=1; exit 2}
          end=pos+length($0); if($0 ~ /\r$/) end--
          print "C",start,end-start,kind; cursor=end; inside=0; certs++
        } else if(line ~ /-----END .*CERTIFICATE-----/) {bad=1; exit 2}
        pos+=length($0)+1
      }
      END {if(bad || inside || certs==0) exit 2; if(total>cursor) print "G",cursor,total-cursor,"NONE"}
    ' "$input" > "$EM_WORK/index" || { em_reason 'Empty/malformed/truncated PEM bundle'; return 2; }
    : > "$output" || return 2
    while read -r type offset count kind; do
        em_out "$EM_WORK/span" 10 dd if="$input" bs=1 skip="$offset" count="$count" || return 2
        if [[ $type == C ]]; then
            em_cert "$EM_WORK/span" "$kind" || return 2
            EM_COUNT=$((EM_COUNT + 1))
            case " $EM_ROOT_HASHES " in *" $EM_FP "*) EM_MATCHES=$((EM_MATCHES + 1)); continue;; esac
        fi
        cat "$EM_WORK/span" >> "$output" || return 2
    done < "$EM_WORK/index"
}

em_bundle() {
    local file=$1
    if ! em_out "$EM_WORK/input" 30 cat "$file" || ! em_parse "$EM_WORK/input" "$EM_WORK/filtered"; then
        em_error "$file: $EM_REASON"; return
    fi
    if [[ $EM_MATCHES -gt 0 ]]; then
        EM_AFFECTED=$((EM_AFFECTED + 1))
        em_log WARN "$file: $EM_MATCHES listed issuer root(s) present; this is not a vulnerability verdict"
    else em_log PASS "No listed issuer roots in $file"; fi
    EM_CHECKED=$((EM_CHECKED + 1))
}

em_java_list() {
    local file=$1 prefix=$2 i alias type
    EM_ALIASES=()
    em_out "$prefix.list" 30 keytool -J-Duser.language=en -J-Duser.country=US -list -rfc -keystore "$file" -storepass changeit || return 2
    awk -v prefix="$prefix" '
      /^Alias name: / {n++; f=prefix ".alias." n; printf "%s",substr($0,13) > f; close(f); next}
      n {print > (prefix ".body." n)}
      END {print n+0 > (prefix ".count")}
    ' "$prefix.list" || return 2
    read -r i < "$prefix.count"
    if [[ $i == 0 ]]; then
        grep -q '0 entries' "$prefix.list" || { em_reason 'Unrecognized Java RFC listing'; return 2; }
        return 0
    fi
    while [[ $i -gt 0 ]]; do
        alias=$(cat "$prefix.alias.$i")
        [[ -n $alias ]] || { em_reason 'Empty Java alias'; return 2; }
        em_parse "$prefix.body.$i" "$EM_WORK/filtered" || return 2
        if [[ $EM_MATCHES -gt 0 ]]; then
            awk '/^Entry type: / {sub(/\r$/, ""); types++; if($0=="Entry type: trustedCertEntry") trusted++} END {exit !(types==1 && trusted==1)}' "$prefix.body.$i" || { em_reason 'Listed root in an ambiguous/private-key/non-trust entry; inspection incomplete'; return 2; }
            EM_ALIASES[${#EM_ALIASES[@]}]=$alias
        fi
        i=$((i - 1))
    done
}

em_java() {
    local file=$1 count
    em_java_list "$file" "$EM_WORK/java-before" || { em_error "Java $file: $EM_REASON"; return; }
    count=${#EM_ALIASES[@]}
    if [[ $count -gt 0 ]]; then
        EM_AFFECTED=$((EM_AFFECTED + 1)); em_log WARN "Java $file: $count trust entries containing listed issuer roots"
    else em_log PASS "Java $file has no listed issuer root trust entries"; fi
    EM_CHECKED=$((EM_CHECKED + 1))
}

em_mac_export() {
    local rc text
    if em_out "$EM_WORK/export.out" 30 security trust-settings-export -d "$EM_WORK/admin.plist"; then
        em_out "$EM_WORK/plist-check" 10 plutil -extract trustList raw -expect dictionary -o - "$EM_WORK/admin.plist" || return 2
        EM_EMPTY_POLICY=0
    else
        rc=$?; text=$(cat "$EM_WORK/command.err")
        if [[ $rc == 1 && $text == 'SecTrustSettingsCreateExternalRepresentation: No Trust Settings were found.' ]]; then EM_EMPTY_POLICY=1
        else return 2; fi
    fi
}

em_mac_has_deny() {
    local fp=$1 i=0 text rc path setting
    [[ $EM_EMPTY_POLICY == 0 ]] || return 1
    path="trustList.$fp"
    if ! em_out "$EM_WORK/plist-check" 10 plutil -extract "$path" raw -expect dictionary -o - "$EM_WORK/admin.plist"; then
        # Only a missing key is absent; a malformed record/export remains an error.
        text=$(cat "$EM_WORK/command.err" "$EM_WORK/plist-check")
        case "$text" in *'No value at that key path'*) return 1;; *) return 2;; esac
    fi
    path="$path.trustSettings"
    em_out "$EM_WORK/plist-count" 10 plutil -extract "$path" raw -expect array -o - "$EM_WORK/admin.plist" || return 2
    read -r setting < "$EM_WORK/plist-count"
    [[ $setting =~ ^[0-9]+$ ]] || { em_reason 'Unrecognized native trust-settings array'; return 2; }
    while [[ $i -lt $setting ]]; do
        em_out "$EM_WORK/plist-keys" 10 plutil -extract "$path.$i" raw -expect dictionary -o - "$EM_WORK/admin.plist" || return 2
        text=$(cat "$EM_WORK/plist-keys")
        if [[ $text == kSecTrustSettingsResult ]]; then
            em_out "$EM_WORK/plist-value" 10 plutil -extract "$path.$i.kSecTrustSettingsResult" raw -expect integer -o - "$EM_WORK/admin.plist" || return 2
            text=$(cat "$EM_WORK/plist-value")
            [[ $text != 3 ]] || return 0
        fi
        i=$((i + 1))
    done
    return 1
}

em_mac_native() {
    local sha1 rc missing=0
    em_mac_export || { em_error "Native macOS export: $EM_REASON"; return; }
    for sha1 in "${EM_SHA1[@]}"; do
        if em_mac_has_deny "$sha1"; then continue; else rc=$?; fi
        if [[ $rc != 1 ]]; then em_error "Native macOS policy parse: $EM_REASON"; return; fi
        missing=$((missing + 1))
    done
    if [[ $missing -gt 0 ]]; then
        EM_AFFECTED=$((EM_AFFECTED + 1))
        em_log WARN "Native macOS lacks $missing explicit administrative intermediate denies; vendor protection may already apply"
    else em_log PASS 'Native macOS: all 16 explicit administrative intermediate denies verified'; fi
    EM_CHECKED=$((EM_CHECKED + 1))
}

em_probe() {
    local kind generation suffix host rc
    for kind in dv ov ev; do for generation in g3b g3c; do for suffix in '' '-aaa'; do
        host="$kind-$generation$suffix-emudhra.we-have-a-problem.com"
        if em_run 12 curl -q --silent --show-error --head --connect-timeout 4 --max-time 10 --noproxy '*' "https://$host/"; then
            em_log INFO "Probe accepted the currently presented chain at $host; not a pinned affected-chain assertion"
        else
            rc=$?
            if [[ $rc == 60 ]]; then em_log INFO "Probe rejected the presented certificate at $host; rejection cause not inferred"
            else em_error "Probe $host: $EM_REASON"; fi
        fi
    done; done; done
}

em_process() {
    local file=$1 resolved parent base item
    parent=${file%/*}; [[ $parent != "$file" ]] || parent=.
    base=${file##*/}
    if ! resolved=$(cd -P -- "$parent" && printf '%s/%s' "$PWD" "$base"); then em_error "Cannot resolve $file"; return; fi
    for item in ${EM_SEEN[@]+"${EM_SEEN[@]}"}; do [[ $item != "$resolved" ]] || return; done
    EM_SEEN[${#EM_SEEN[@]}]=$resolved
    em_bundle "$file"
}

em_usage() {
    printf '%s\n' "Usage: ${0##*/} [--bundle PATH] [--java-keystore PATH] [--probe] [--color auto|always|never]" \
      'Read-only audit. Offline by default. No sudo or Python required. Explicit stores replace the default scope.' \
      'Exit 0: selected checks complete, no observations; 1: listed root/missing local deny; 2: incomplete/error.' \
      'Root presence and missing local denies do not establish vulnerability; vendor controls may already protect the client.'
}

em_init() {
    if [[ $EUID == 0 ]]; then
        if [[ $EM_PLATFORM == mac ]]; then EM_HOME=/var/root; else EM_HOME=/root; fi
    else EM_HOME=${HOME:-/}; fi
    EM_WORK=$(mktemp -d /tmp/emudhra.XXXXXXXX) || return 2
    mkfifo "$EM_WORK/clock" || return 2
    trap em_cleanup EXIT
    trap 'exit 130' INT TERM HUP
    em_embedded || return 2
    local fp
    for fp in "${EM_ROOTS[@]}" "${EM_INTERS[@]}"; do
        em_cert "$EM_WORK/certs/$fp.pem" PLAIN || return 2
        [[ $EM_FP == "$fp" ]] || { em_reason 'Embedded certificate fingerprint mismatch'; return 2; }
    done
}

em_main() {
    local name value actual path found=0
    while [[ $# -gt 0 ]]; do
        name=$1; shift
        case "$name" in
          --help|-h) em_usage; return 0;;
          --bundle|--java-keystore|--color)
            [[ $# -gt 0 ]] || { printf '%s\n' "Missing argument: $name" >&2; return 2; }
            value=$1; shift
            case "$name" in
              --bundle) EM_BUNDLES[${#EM_BUNDLES[@]}]=$value; EM_EXPLICIT=1;;
              --java-keystore) EM_JAVA[${#EM_JAVA[@]}]=$value; EM_EXPLICIT=1;;
              --color) case "$value" in auto|always|never) EM_COLOR=$value;; *) printf '%s\n' 'Invalid color mode' >&2; return 2;; esac;;
            esac;;
          --probe) EM_PROBE=1;;
          *) printf '%s\n' "Unknown argument: $name" >&2; return 2;;
        esac
    done
    actual=$(uname -s)
    if [[ ( $EM_PLATFORM == mac && $actual != Darwin ) || ( $EM_PLATFORM == linux && $actual != Linux ) ]]; then em_log ERROR "Wrong platform: $actual"; return 2; fi
    for name in openssl awk dd cmp mktemp mkfifo tr head cat wc mkdir rm env; do
        command -v "$name" >/dev/null 2>&1 || { em_log ERROR "Required native tool missing: $name"; return 2; }
    done
    if ! em_init; then em_log ERROR "Initialization failed: $EM_REASON"; return 2; fi
    if [[ $EM_EXPLICIT == 1 ]]; then
        for path in ${EM_BUNDLES[@]+"${EM_BUNDLES[@]}"}; do em_process "$path"; done
        for path in ${EM_JAVA[@]+"${EM_JAVA[@]}"}; do em_java "$path"; done
    else
        if [[ $EM_PLATFORM == mac ]]; then
            em_mac_native
            for path in /etc/ssl/cert.pem /opt/homebrew/etc/ca-certificates/cert.pem /opt/homebrew/etc/openssl@3/cert.pem /usr/local/etc/ca-certificates/cert.pem /usr/local/etc/openssl@3/cert.pem; do
                if [[ -e $path || -L $path ]]; then found=1; em_process "$path"; fi
            done
        else
            for path in /etc/ssl/certs/ca-certificates.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /var/lib/ca-certificates/ca-bundle.pem /etc/ssl/cert.pem; do
                if [[ -e $path || -L $path ]]; then found=1; em_process "$path"; fi
            done
        fi
        [[ $found == 1 ]] || em_error 'No supported native PEM bundle was inspected; use --bundle for another path'
    fi
    [[ $EM_PROBE == 0 ]] || em_probe
    [[ $EM_CHECKED -gt 0 ]] || em_error 'No trust store was successfully inspected'
    em_log INFO "Complete: $EM_CHECKED checked; $EM_AFFECTED observations; $EM_BAD incomplete"
    em_log INFO 'Local inventory only. Listed roots or missing local denies do not establish vulnerability. Vendor revocation and independent app stores require separate checks.'
    if [[ $EM_BAD -gt 0 ]]; then return 2; elif [[ $EM_AFFECTED -gt 0 ]]; then return 1; else return 0; fi
}

em_embedded() {
    mkdir "$EM_WORK/certs" || return 2
    EM_ROOTS=(7DD78D5F4F13459A83DFF9ABBBA62EDBAF6F2D102BF257FD712F4D9F2746ED8D F2EDAAFF3D9B701FB4D14C9F285F8C0BAD90FC3BCC1FA07D47F4718EDABA34A5 D7A7A0FB5D7E2731D771E9484EBCDEF71D5F0C3E0A2948782BC83EE0EA699EF4 86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B)
    EM_INTERS=(42C4ACCD12C4F59597925E1A08A7A90102608543809308D50EC427E118BA1493 45A883F349AEDFD5F3A649B5498FFB121712BA8B448F3F2A91DBC5A766FCDDBE 98B896625C0C230ADEEC3EB2CF6AAD5001ECF9156A68644E82374CE5833BC25B 5F1DED4DD590AF74631290CF073B122A2AAC6A1FA479778A0BD43579BD832699 E7568FE6E12331F4FD7DE61DA4C7559D0F8EB192A218D4741A3BA75184333838 579480AEA166290BD3C643589E795FC0D0E54E86505D180F1DFF99EFD3199512 0164D7CEAE5BB909C272AF151FF44B1177AE9B47D9424B94F1D9558C30934D19 62B7F9868263F72F6911FC78CEAF72C1979158B7368BF648683BB2AA39B02E72 CB6E15165AC802E9B3F993F16C25D41F4E81C21EBDE71AE1B012AC00BF9C7C3F 7485B51C0ED192878FA1D2F948FB529AE1842CC5086C4B67F7BE5B2039DE9489 432EC25F0D28DE9006D97BF752F17BBB2CD41F669933FCB072D9A1148D0261F3 FD9D5C2DBBD4995AB69B8D50C439D9527B00529199C2FD01B2174EB58F07021F 9E39DE2881273ACC225A149C72BA3E0F51424963669AB633EE1DC7DF5DB067B4 A496E23AC0CAB8155FC9B117B97EAE368EFCBB9041AEC8804D5A308D2D01C2D8 4B2460A466F95FD40113BCDCCA2CEB29B3B093921DE45474DA7DF48874C630B1 84112972B8E59D14560AE7E7119654474AAD119990CF3722BFC1E3B91615E1FD)
    EM_SHA1=(A99B289464F3B44343270A7A1E910F02370483FE 1396BE1372BC93DFA2A433CA964DBA91548A6E57 5F014E0DB3BB8F950E0598AB280846D383FC57BE 5DFA19197D1C1CF629AF7C0CD865543C5050227C F33ACD1F5D31AA81AC18C72C928446226D3D5914 19069BD6533BFF93FB67C71FB3376B4EA7402C3B 8AD23BC78845D6FAAE1D534BAC89F0E36BA55A11 4B0944C14F8C2CCBA4E4F32104AD920FA15EE331 7FCC31AAB874CE6C8EE8584F54CFD08646B54117 305FC1E253DCAB71B95D4995DAE3CB09D562F22A C988F3D0CC1629FFC43165D6464C9B6EF73D6E48 8588708E875A1F8AA83524F3559080F7E17068C7 D33195A244046A3263FB5E0E83C6803A5B2E7BC3 EE26D7AE3CC71718F6E07D7D0095076F0C158F63 1F4A5D178F8B6A8EF0F6784155BD5FEA91158B12 7FDE64753A957B98F172FD2AB0D922551909C7BA)
    EM_ROOT_HASHES="${EM_ROOTS[*]}"
    cat > "$EM_WORK/certs/7DD78D5F4F13459A83DFF9ABBBA62EDBAF6F2D102BF257FD712F4D9F2746ED8D.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIICKTCCAa+gAwIBAgIQDnYGcvFDRZ/I/gqwvAXjlDAKBggqhkjOPQQDAzBWMQsw
CQYDVQQGEwJJTjElMCMGA1UECgwcZU11ZGhyYSBUZWNobm9sb2dpZXMgTGltaXRl
ZDEgMB4GA1UEAwwXZW1TaWduIFJvb3QgVExTIENBIC0gRzMwHhcNMjQwMjA4MDgx
OTMyWhcNNDkwMjA3MDgxOTMyWjBWMQswCQYDVQQGEwJJTjElMCMGA1UECgwcZU11
ZGhyYSBUZWNobm9sb2dpZXMgTGltaXRlZDEgMB4GA1UEAwwXZW1TaWduIFJvb3Qg
VExTIENBIC0gRzMwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAARfD9w/q1cWxL6D9bMG
H6CQ4u+gAV6GN9s+PwQx9Bl4hC+0iU8QOk8mWO/RwXQy10DCSxT8vSIJClHKp+Ao
4qJKdYeV0SwZ7LMQziyLfxIUOY6Grja/sQFwLKYf8EdDXAyjQjBAMB0GA1UdDgQW
BBThOqshfPHjTVSu1HK3/YtZQiCQVDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/
BAUwAwEB/zAKBggqhkjOPQQDAwNoADBlAjBhCFTkly7Yl7+s4hiw+k6ZJTXT2AiI
rvmsmfqPr5E7ecwXb6kXA5LTFd6rjwTuV3sCMQC9w6ZSbVq1mveMO6dKFziOzClT
KCT2RFT6yXtq6nzgRICgBmiXbJAXsmZ8yAwjyWc=
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/F2EDAAFF3D9B701FB4D14C9F285F8C0BAD90FC3BCC1FA07D47F4718EDABA34A5.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIICKDCCAa2gAwIBAgIQAY/OySfBFvWcmX7cDM0uKzAKBggqhkjOPQQDAzBVMQsw
CQYDVQQGEwJJTjElMCMGA1UECgwcZU11ZGhyYSBUZWNobm9sb2dpZXMgTGltaXRl
ZDEfMB0GA1UEAwwWZW1TaWduIFJvb3QgQ1MgQ0EgLSBHMzAeFw0yNDAyMDgwODMz
MTRaFw00OTAyMDcwODMzMTRaMFUxCzAJBgNVBAYTAklOMSUwIwYDVQQKDBxlTXVk
aHJhIFRlY2hub2xvZ2llcyBMaW1pdGVkMR8wHQYDVQQDDBZlbVNpZ24gUm9vdCBD
UyBDQSAtIEczMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAESl9kM5D0VA/Og76dz5Xz
w1hnGQ4fSR9993/qBkkvI48pXQVKOdyHCgAZThgWejQ8OpFRiTISjpabn4tfRFOY
uzhApR/XxGbkg9X+2cEtbyghF9CdoF91W22V/R2EVe4xo0IwQDAdBgNVHQ4EFgQU
aHQD+IXKjVRQVx0W4MjeRQ2rzS0wDgYDVR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQF
MAMBAf8wCgYIKoZIzj0EAwMDaQAwZgIxAK9OlACrFod3UgWY1ai+DF9sGFhahU59
rv4jJyV01QaxGn0HErZ8gjHkngqe+tcFogIxAPTdW0hBmrGjhxBWdv9mZNdVFiJ4
lrZ3ahvimsLhTQpnDBgiGKv6Ov1Fx/CE6yjIAg==
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/D7A7A0FB5D7E2731D771E9484EBCDEF71D5F0C3E0A2948782BC83EE0EA699EF4.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIEMjCCAxqgAwIBAgIBATANBgkqhkiG9w0BAQUFADB7MQswCQYDVQQGEwJHQjEb
MBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVyMRAwDgYDVQQHDAdTYWxmb3JkMRow
GAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEhMB8GA1UEAwwYQUFBIENlcnRpZmlj
YXRlIFNlcnZpY2VzMB4XDTA0MDEwMTAwMDAwMFoXDTI4MTIzMTIzNTk1OVowezEL
MAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4GA1UE
BwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAfBgNVBAMM
GEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczCCASIwDQYJKoZIhvcNAQEBBQADggEP
ADCCAQoCggEBAL5AnfRu4ep2hxxNRUSOvkbIgwadwSr+GB+O5AL686tdUIoWMQua
BtDFcCLNSS1UY8y2bmhGC1Pqy0wkwLxyTurxFa70VJoSCsN6sjNg4tqJVfMiWPPe
3M/vg4aijJRPn2jymJBGhCfHdr/jzDUsi14HZGWCwEiwqJH5YZ92IFCokcdmtet4
YgNW8IoaE+oxox6gmf049vYnMlhvB/VruPsUK6+3qszWY19zjNoFmag4qMsXeDZR
rOme9Hg6jc8P2ULimAyrL58OAd7vn5lJ8S3frHRNG5i1R8XlKdH5kBjHYpy+g8cm
ez6KJcfA3Z3mNWgQIJ2P2N7Sw4ScDV7oL8kCAwEAAaOBwDCBvTAdBgNVHQ4EFgQU
oBEKIz6W8Qfs4q8p74Klf9AwpLQwDgYDVR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQF
MAMBAf8wewYDVR0fBHQwcjA4oDagNIYyaHR0cDovL2NybC5jb21vZG9jYS5jb20v
QUFBQ2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNqA0oDKGMGh0dHA6Ly9jcmwuY29t
b2RvLm5ldC9BQUFDZXJ0aWZpY2F0ZVNlcnZpY2VzLmNybDANBgkqhkiG9w0BAQUF
AAOCAQEACFb8AvCb6P+k+tZ7xkSAzk/ExfYAWMymtrwUSWgEdujm7l3sAg9g1o1Q
GE8mTgHj5rCl7r+8dFRBv/38ErjHT1r0iWAFf2C3BUrz9vHCv8S5dIa2LX1rzNLz
Rt0vxuBqw8M0Ayx9lt1awg6nCpnBBYurDC/zXDrPbDdVCYfeU0BsWO/8tqtlbgT2
G9w84FoVxp7Z8VlIMCFlA2zs6SFz7JsDoeA3raAVGI/6ugLOpyypEBMs1OUIJqsi
l2D4kF501KKaU73yqWjgom7C12yxow+ev+to51byrvLjKzg6CYG1a4XXvi3tPxq3
smPi9WIsgtRqAEFQ8TmDn5XpNpaYbg==
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIICTjCCAdOgAwIBAgIKPPYHqWhwDtqLhDAKBggqhkjOPQQDAzBrMQswCQYDVQQG
EwJJTjETMBEGA1UECxMKZW1TaWduIFBLSTElMCMGA1UEChMcZU11ZGhyYSBUZWNo
bm9sb2dpZXMgTGltaXRlZDEgMB4GA1UEAxMXZW1TaWduIEVDQyBSb290IENBIC0g
RzMwHhcNMTgwMjE4MTgzMDAwWhcNNDMwMjE4MTgzMDAwWjBrMQswCQYDVQQGEwJJ
TjETMBEGA1UECxMKZW1TaWduIFBLSTElMCMGA1UEChMcZU11ZGhyYSBUZWNobm9s
b2dpZXMgTGltaXRlZDEgMB4GA1UEAxMXZW1TaWduIEVDQyBSb290IENBIC0gRzMw
djAQBgcqhkjOPQIBBgUrgQQAIgNiAAQjpQy4LRL1KPOxst3iAhKAnjlfSU2fySU0
WXTsuwYc58Byr+iuL+FBVIcUqEqy6HyC5ltqtdyzdc6LBtCGI79G1Y4PPwT01xyS
fvalY8L1X44uT6EYGQIrMgqCZH0Wk9GjQjBAMB0GA1UdDgQWBBR8XQKEE9TMipuB
zhccLikenEhjQjAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAKBggq
hkjOPQQDAwNpADBmAjEAvvNhzwIQHWSVB7gYboiFBS+DCBeQyh+KTOgNG3qxrdWB
CUfvO6wIBHxcmbHtRwfSAjEAnbpV/KlK6O3t5nYBQnvI+GDZjVGLVTv7jHvrZQnD
+JbNR6iC8hZVdyR+EhCVBCyj
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/42C4ACCD12C4F59597925E1A08A7A90102608543809308D50EC427E118BA1493.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDaDCCAu6gAwIBAgIQAKSu5njyM2K0wORgt3LyFDAKBggqhkjOPQQDAzBWMQsw
CQYDVQQGEwJJTjElMCMGA1UECgwcZU11ZGhyYSBUZWNobm9sb2dpZXMgTGltaXRl
ZDEgMB4GA1UEAwwXZW1TaWduIFJvb3QgVExTIENBIC0gRzMwHhcNMjUwNDMwMTU1
NDA4WhcNNDAwNDI4MTgzMDAwWjA/MQswCQYDVQQGEwJOTDETMBEGA1UECgwKZU11
ZGhyYSBCVjEbMBkGA1UEAwwSRU0gRFYgVExTIENBIC0gRzNCMHYwEAYHKoZIzj0C
AQYFK4EEACIDYgAE557ZwEqXc8RzXlERHahawr1eZKs3S4DhLLwgOOweTw47gS/J
hZ4eZ6+wTi+LyX90hbplqpEe6KTkW2LVzAPVa+Z4s8OMtNyTfKJGDiOEU8iSk10p
1E+R4VYGtjzO2rRoo4IBljCCAZIwHwYDVR0jBBgwFoAU4TqrIXzx401UrtRyt/2L
WUIgkFQwHQYDVR0OBBYEFOIeL+ccGTkOVUtiwSAkVzUkiiUUMB0GA1UdJQQWMBQG
CCsGAQUFBwMBBggrBgEFBQcDAjBdBgNVHSAEVjBUMDkGCysGAQQBg44hAQABMCow
KAYIKwYBBQUHAgEWHGh0dHA6Ly9yZXBvc2l0b3J5LmVtc2lnbi5jb20wDQYLKwYB
BAGDjiEBAmQwCAYGZ4EMAQIBMHUGCCsGAQUFBwEBBGkwZzAkBggrBgEFBQcwAYYY
aHR0cDovL29jc3AtYi5lbXNpZ24uY29tMD8GCCsGAQUFBzAChjNodHRwOi8vcmVw
b3NpdG9yeS5lbXNpZ24uY29tL2NlcnRzL0VNRFZUTFNDQUczQi5wN2MwNwYDVR0f
BDAwLjAsoCqgKIYmaHR0cDovL2NybC5lbXNpZ24uY29tLz9yb290dGxzY2FnMy5j
cmwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQAwCgYIKoZIzj0E
AwMDaAAwZQIwLmsGXi6oFMJ2klkcEMXMug6gvxQWZWkewiDWVzQyl2L6z6DuQfPO
Ibh1grvdULDCAjEAxZvLlxUavG69J6wnSjC8XBbqNIQsJ6CE2QdNOe84Ptxb6VG8
gt2TlfJbHii+KNvK
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/45A883F349AEDFD5F3A649B5498FFB121712BA8B448F3F2A91DBC5A766FCDDBE.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDzjCCAragAwIBAgIRAKAk/fS6Zlx4XOSgIEg4WLcwDQYJKoZIhvcNAQELBQAw
ezELMAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4G
A1UEBwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAfBgNV
BAMMGEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczAeFw0yNTA1MTQwMDAwMDBaFw0y
ODEyMzEyMzU5NTlaMD8xCzAJBgNVBAYTAk5MMRMwEQYDVQQKDAplTXVkaHJhIEJW
MRswGQYDVQQDDBJFTSBEViBUTFMgQ0EgLSBHM0IwdjAQBgcqhkjOPQIBBgUrgQQA
IgNiAATnntnASpdzxHNeUREdqFrCvV5kqzdLgOEsvCA47B5PDjuBL8mFnh5nr7BO
L4vJf3SFumWqkR7opORbYtXMA9Vr5nizw4y03JN8okYOI4RTyJKTXSnUT5HhVga2
PM7atGijggE1MIIBMTAfBgNVHSMEGDAWgBSgEQojPpbxB+zirynvgqV/0DCktDAd
BgNVHQ4EFgQU4h4v5xwZOQ5VS2LBICRXNSSKJRQwDgYDVR0PAQH/BAQDAgEGMBIG
A1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMC
MDEGA1UdIAQqMCgwCAYGZ4EMAQIBMA0GCysGAQQBg44hAQABMA0GCysGAQQBg44h
AQJkMEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FB
QUNlcnRpZmljYXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEF
BQcwAYYYaHR0cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBCwUAA4IB
AQBzQ1IoqpdotM6gFrR4Q3YrKifOLeaj5XXunldpVE/vZn2TxC2y0s8oYiLR5ICE
wqVXSB7N6BM1Mp+Nif7Jbhb2IswAfSR4Iik8+B0iRmi7lYoNlycCgHjmsjOmZaxM
QkPmjXAJbG5f4V41OsvJZmS7lI3r0IuvEDVX3GAZ13on6IImSs9ybNpHQ7NCqkMQ
7wH4uAO1dtpFycgJSdHaCOhHjrox2BTYGLdpUrYwY3EOAjlZ8UGgsxs7mG+xquMl
bN1LFURwfnkVMP3T/DBIZ/ys2+lNFyxK3FlArrV4/000uTnVB1lO8oGORYdXoT5V
GUyRCEIDhF5TBUuKF4E3kf1h
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/98B896625C0C230ADEEC3EB2CF6AAD5001ECF9156A68644E82374CE5833BC25B.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDZjCCAu2gAwIBAgIPbK2jZ/scEACIEg6iAtVoMAoGCCqGSM49BAMDMFYxCzAJ
BgNVBAYTAklOMSUwIwYDVQQKDBxlTXVkaHJhIFRlY2hub2xvZ2llcyBMaW1pdGVk
MSAwHgYDVQQDDBdlbVNpZ24gUm9vdCBUTFMgQ0EgLSBHMzAeFw0yNTA0MzAxNjAw
MTJaFw00MDA0MjgxODMwMDBaMD8xCzAJBgNVBAYTAk5MMRMwEQYDVQQKDAplTXVk
aHJhIEJWMRswGQYDVQQDDBJFTSBPViBUTFMgQ0EgLSBHM0IwdjAQBgcqhkjOPQIB
BgUrgQQAIgNiAARziXqg6zz9yosSQC/68KvE4SErr43ud4rJ7i1tuD+sKAxeBWOK
56Ks1xwyKo42HN659pxDArndjXPRzGyqsswK7k4hbOl53VGKSvS2JuVoTN1lgDft
DIVOTMEvTPhkbQ2jggGWMIIBkjAfBgNVHSMEGDAWgBThOqshfPHjTVSu1HK3/YtZ
QiCQVDAdBgNVHQ4EFgQUm9hlUa/n5yw3rQjuaRnZvzeErgowHQYDVR0lBBYwFAYI
KwYBBQUHAwEGCCsGAQUFBwMCMF0GA1UdIARWMFQwOQYLKwYBBAGDjiEBAAEwKjAo
BggrBgEFBQcCARYcaHR0cDovL3JlcG9zaXRvcnkuZW1zaWduLmNvbTANBgsrBgEE
AYOOIQECbjAIBgZngQwBAgIwdQYIKwYBBQUHAQEEaTBnMCQGCCsGAQUFBzABhhho
dHRwOi8vb2NzcC1iLmVtc2lnbi5jb20wPwYIKwYBBQUHMAKGM2h0dHA6Ly9yZXBv
c2l0b3J5LmVtc2lnbi5jb20vY2VydHMvRU1PVlRMU0NBRzNCLnA3YzA3BgNVHR8E
MDAuMCygKqAohiZodHRwOi8vY3JsLmVtc2lnbi5jb20vP3Jvb3R0bHNjYWczLmNy
bDAOBgNVHQ8BAf8EBAMCAQYwEgYDVR0TAQH/BAgwBgEB/wIBADAKBggqhkjOPQQD
AwNnADBkAjBAk+5BizdJhrED3wb7F2Gm7bWI60dlNd075nghT2TrR4NWKZtJZcbc
28xxIY/NONICMF6mPdsjosaqmvEMWqKcBh4vsIvXSKnQj5o8zrFB4oKS+accjYTe
8Dz3bQjauvy9uw==
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/5F1DED4DD590AF74631290CF073B122A2AAC6A1FA479778A0BD43579BD832699.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDzjCCAragAwIBAgIRAOlCI73pL5FOWrmsq/2sNxAwDQYJKoZIhvcNAQELBQAw
ezELMAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4G
A1UEBwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAfBgNV
BAMMGEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczAeFw0yNTA1MTQwMDAwMDBaFw0y
ODEyMzEyMzU5NTlaMD8xCzAJBgNVBAYTAk5MMRMwEQYDVQQKDAplTXVkaHJhIEJW
MRswGQYDVQQDDBJFTSBPViBUTFMgQ0EgLSBHM0IwdjAQBgcqhkjOPQIBBgUrgQQA
IgNiAARziXqg6zz9yosSQC/68KvE4SErr43ud4rJ7i1tuD+sKAxeBWOK56Ks1xwy
Ko42HN659pxDArndjXPRzGyqsswK7k4hbOl53VGKSvS2JuVoTN1lgDftDIVOTMEv
TPhkbQ2jggE1MIIBMTAfBgNVHSMEGDAWgBSgEQojPpbxB+zirynvgqV/0DCktDAd
BgNVHQ4EFgQUm9hlUa/n5yw3rQjuaRnZvzeErgowDgYDVR0PAQH/BAQDAgEGMBIG
A1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMC
MDEGA1UdIAQqMCgwCAYGZ4EMAQICMA0GCysGAQQBg44hAQABMA0GCysGAQQBg44h
AQJuMEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FB
QUNlcnRpZmljYXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEF
BQcwAYYYaHR0cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBCwUAA4IB
AQALRoOSvkzRa+tN5Rje9W5GiXd/qsicd9N6Gnh0SWC7VyWH+HycIqAnFCMYZznj
CeGusomFYHE42SHWr85JDIbgzy6y3dO4i9n9w0Bx7yrXWBbDzFS8VgA3+EY4Cg7y
mtoC3RPOJVtaXXPZ+68X804g1Mj+3vCSHj2lNPVgco0OzSIOJ/KMg1R9MLBkiKzb
bERAGZHejY0HBhYd76IINZN8z6bBNah2UdFYxsOisLynPQUkol6gRLum024/FzVl
CCDfnUusrkr+mAfPAvD/Vb8bhpA7jYtepuU+2mIdShj5lLlvAwZphn+ypWycuo2x
0k9mldz2dqI9nhCiY+TTIOOR
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/E7568FE6E12331F4FD7DE61DA4C7559D0F8EB192A218D4741A3BA75184333838.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDaDCCAu2gAwIBAgIQAMfEHv6S2CXwXq6EGkqCwTAKBggqhkjOPQQDAzBWMQsw
CQYDVQQGEwJJTjElMCMGA1UECgwcZU11ZGhyYSBUZWNobm9sb2dpZXMgTGltaXRl
ZDEgMB4GA1UEAwwXZW1TaWduIFJvb3QgVExTIENBIC0gRzMwHhcNMjUwNDMwMTYw
MzMxWhcNNDAwNDI4MTgzMDAwWjA/MQswCQYDVQQGEwJOTDETMBEGA1UECgwKZU11
ZGhyYSBCVjEbMBkGA1UEAwwSRU0gRVYgVExTIENBIC0gRzNCMHYwEAYHKoZIzj0C
AQYFK4EEACIDYgAEJduoWmTTl9oLEFLp6lRuSHvv6pydnWigxerc/u91ppu11vwB
9Cv7ym60C81kwHZ+Nv/QXZeoE8WqDGyVMOec9fCGZGjxOAZCCqXIUYQLHiUlQOeQ
5LZUw4Uu1krx6GV9o4IBlTCCAZEwHwYDVR0jBBgwFoAU4TqrIXzx401UrtRyt/2L
WUIgkFQwHQYDVR0OBBYEFD7cINmJRpiHe4c/2IFHslwV2EcGMB0GA1UdJQQWMBQG
CCsGAQUFBwMBBggrBgEFBQcDAjBcBgNVHSAEVTBTMDkGCysGAQQBg44hAQABMCow
KAYIKwYBBQUHAgEWHGh0dHA6Ly9yZXBvc2l0b3J5LmVtc2lnbi5jb20wDQYLKwYB
BAGDjiEBAngwBwYFZ4EMAQEwdQYIKwYBBQUHAQEEaTBnMCQGCCsGAQUFBzABhhho
dHRwOi8vb2NzcC1iLmVtc2lnbi5jb20wPwYIKwYBBQUHMAKGM2h0dHA6Ly9yZXBv
c2l0b3J5LmVtc2lnbi5jb20vY2VydHMvRU1FVlRMU0NBRzNCLnA3YzA3BgNVHR8E
MDAuMCygKqAohiZodHRwOi8vY3JsLmVtc2lnbi5jb20vP3Jvb3R0bHNjYWczLmNy
bDAOBgNVHQ8BAf8EBAMCAQYwEgYDVR0TAQH/BAgwBgEB/wIBADAKBggqhkjOPQQD
AwNpADBmAjEA9Jq999oaOUKhFwopw33iCmt0OHIn3gjT43GfuOHR/YckXdwoNdDA
lIEhz0NgRO3/AjEAvY/a3OMvktIZLYjn+WLKmp0QhrIMV+e6EpS7j4GVeOKouNp6
MN/P+ByGeiRMghzB
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/579480AEA166290BD3C643589E795FC0D0E54E86505D180F1DFF99EFD3199512.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDzTCCArWgAwIBAgIRANj4aF5PK9nYJAKoWhwetzEwDQYJKoZIhvcNAQELBQAw
ezELMAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4G
A1UEBwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAfBgNV
BAMMGEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczAeFw0yNTA1MTQwMDAwMDBaFw0y
ODEyMzEyMzU5NTlaMD8xCzAJBgNVBAYTAk5MMRMwEQYDVQQKDAplTXVkaHJhIEJW
MRswGQYDVQQDDBJFTSBFViBUTFMgQ0EgLSBHM0IwdjAQBgcqhkjOPQIBBgUrgQQA
IgNiAAQl26haZNOX2gsQUunqVG5Ie+/qnJ2daKDF6tz+73Wmm7XW/AH0K/vKbrQL
zWTAdn42/9Bdl6gTxaoMbJUw55z18IZkaPE4BkIKpchRhAseJSVA55DktlTDhS7W
SvHoZX2jggE0MIIBMDAfBgNVHSMEGDAWgBSgEQojPpbxB+zirynvgqV/0DCktDAd
BgNVHQ4EFgQUPtwg2YlGmId7hz/YgUeyXBXYRwYwDgYDVR0PAQH/BAQDAgEGMBIG
A1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMC
MDAGA1UdIAQpMCcwBwYFZ4EMAQEwDQYLKwYBBAGDjiEBAAEwDQYLKwYBBAGDjiEB
AngwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybC5jb21vZG9jYS5jb20vQUFB
Q2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNAYIKwYBBQUHAQEEKDAmMCQGCCsGAQUF
BzABhhhodHRwOi8vb2NzcC5jb21vZG9jYS5jb20wDQYJKoZIhvcNAQELBQADggEB
AJNFuAFW9Gnw/8+kCO4KIlZdnM1Sh2u+8cK0EYAHhXpb5FlGvYkcARigo5oS7VoM
7FOYlTueV6yICZKNAYawZPJPhNCGK+rp3cQBEz6d0n8OZEYZov9lb3ll8ORgSDuf
FVIW6Gagg/UnOamLBTOR8eD5V73SCme/B2cHUDw+m5E8cc+0Ujzz3Cn3ex5JrhXk
2T3s8PoVzEmhTgGboFfcWO1EYhPPrYwdxPYRQIXAXUXhLEOVNL9ASbZJLFI8E1IM
m7NwxVN2s38jWpaCUaaF0tg7hfiy7oe13rzJfHsdqldJVTTUTPWVx8TC4ju0VLet
bAlwhwFT6AP8uIVMGUHNw24=
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/0164D7CEAE5BB909C272AF151FF44B1177AE9B47D9424B94F1D9558C30934D19.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDaDCCAu6gAwIBAgIPWIsuPCu4zaE+GhIJJUMhMAoGCCqGSM49BAMDMFYxCzAJ
BgNVBAYTAklOMSUwIwYDVQQKDBxlTXVkaHJhIFRlY2hub2xvZ2llcyBMaW1pdGVk
MSAwHgYDVQQDDBdlbVNpZ24gUm9vdCBUTFMgQ0EgLSBHMzAeFw0yNTA0MzAxNTM1
MDlaFw00MDA0MjgxODMwMDBaMEAxCzAJBgNVBAYTAlVTMRQwEgYDVQQKDAtlTXVk
aHJhIEluYzEbMBkGA1UEAwwSRU0gRFYgVExTIENBIC0gRzNDMHYwEAYHKoZIzj0C
AQYFK4EEACIDYgAEOnp4YsjETTJN3WkDOmeCwO/u/kBV5ooSP6A3G6O9kZRRTuFy
pDPjYw8CvRiAN9nlFJ+bd9uUooHfmHsv6oiLdL3+j9pMEJnubKGVZv4+8OX2sJpV
bMyLpQVh3xsqRB0Bo4IBljCCAZIwHwYDVR0jBBgwFoAU4TqrIXzx401UrtRyt/2L
WUIgkFQwHQYDVR0OBBYEFK5+EFw8KZbBqEcnBVnx4D3U5QrzMB0GA1UdJQQWMBQG
CCsGAQUFBwMBBggrBgEFBQcDAjBdBgNVHSAEVjBUMDkGCysGAQQBg44hAQABMCow
KAYIKwYBBQUHAgEWHGh0dHA6Ly9yZXBvc2l0b3J5LmVtc2lnbi5jb20wDQYLKwYB
BAGDjiEBAmQwCAYGZ4EMAQIBMHUGCCsGAQUFBwEBBGkwZzAkBggrBgEFBQcwAYYY
aHR0cDovL29jc3AtYy5lbXNpZ24uY29tMD8GCCsGAQUFBzAChjNodHRwOi8vcmVw
b3NpdG9yeS5lbXNpZ24uY29tL2NlcnRzL0VNRFZUTFNDQUczQy5wN2MwNwYDVR0f
BDAwLjAsoCqgKIYmaHR0cDovL2NybC5lbXNpZ24uY29tLz9yb290dGxzY2FnMy5j
cmwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQAwCgYIKoZIzj0E
AwMDaAAwZQIxAMEN2HWMocbuWdy1d33pH6JpMvP/V/DIS5PtZbv1Q7TXEbxrcyxg
yuddOJscYDJJlAIwB4sH1BpbScDzkdD4tJBSwrG/1Mx82vb8YaySehNuu1+1oXNd
AEKwaJ0mVzScy2+6
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/62B7F9868263F72F6911FC78CEAF72C1979158B7368BF648683BB2AA39B02E72.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDzzCCAregAwIBAgIRAJHzR/Glt9OZYrleDuTimdEwDQYJKoZIhvcNAQELBQAw
ezELMAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4G
A1UEBwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAfBgNV
BAMMGEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczAeFw0yNTA1MTQwMDAwMDBaFw0y
ODEyMzEyMzU5NTlaMEAxCzAJBgNVBAYTAlVTMRQwEgYDVQQKDAtlTXVkaHJhIElu
YzEbMBkGA1UEAwwSRU0gRFYgVExTIENBIC0gRzNDMHYwEAYHKoZIzj0CAQYFK4EE
ACIDYgAEOnp4YsjETTJN3WkDOmeCwO/u/kBV5ooSP6A3G6O9kZRRTuFypDPjYw8C
vRiAN9nlFJ+bd9uUooHfmHsv6oiLdL3+j9pMEJnubKGVZv4+8OX2sJpVbMyLpQVh
3xsqRB0Bo4IBNTCCATEwHwYDVR0jBBgwFoAUoBEKIz6W8Qfs4q8p74Klf9AwpLQw
HQYDVR0OBBYEFK5+EFw8KZbBqEcnBVnx4D3U5QrzMA4GA1UdDwEB/wQEAwIBBjAS
BgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcD
AjAxBgNVHSAEKjAoMAgGBmeBDAECATANBgsrBgEEAYOOIQEAATANBgsrBgEEAYOO
IQECZDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsLmNvbW9kb2NhLmNvbS9B
QUFDZXJ0aWZpY2F0ZVNlcnZpY2VzLmNybDA0BggrBgEFBQcBAQQoMCYwJAYIKwYB
BQUHMAGGGGh0dHA6Ly9vY3NwLmNvbW9kb2NhLmNvbTANBgkqhkiG9w0BAQsFAAOC
AQEAr7b6Mx11TIJgVzHt6EH5qGNWeiiqoMrp8E5/k8s+jvupx1n083pZ5XOzUzND
wEUe0W4C4FIGUHNQ4XDwqOw0yK42xqm2dvCKgsko2UvDlT0haZVtTCeWMQOe5J/J
ziaMfZwsZNfZ3aaI6XPtWDZtwY8AaNfyaeCpbtm5GcGnyNWk4jSNpbtpo6NjfXuP
CFOm3rTjJ4zytP7Tso6iMm0L01cYFOlTmoPv4515R2r3SPnKDtijoB/D/vgxzojv
DafgyG9afX8+laO9NbMMz4sqC1vZx3984i/sBNFiugm3Vvdq5OdJRjuGC1QILIs6
dg/K3i8VQqRpbfaM9kIlMzZ3dQ==
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/CB6E15165AC802E9B3F993F16C25D41F4E81C21EBDE71AE1B012AC00BF9C7C3F.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDaDCCAu6gAwIBAgIPKWkmwiejoVJjkrGUgqUEMAoGCCqGSM49BAMDMFYxCzAJ
BgNVBAYTAklOMSUwIwYDVQQKDBxlTXVkaHJhIFRlY2hub2xvZ2llcyBMaW1pdGVk
MSAwHgYDVQQDDBdlbVNpZ24gUm9vdCBUTFMgQ0EgLSBHMzAeFw0yNTA0MzAxNTM3
NDFaFw00MDA0MjgxODMwMDBaMEAxCzAJBgNVBAYTAlVTMRQwEgYDVQQKDAtlTXVk
aHJhIEluYzEbMBkGA1UEAwwSRU0gT1YgVExTIENBIC0gRzNDMHYwEAYHKoZIzj0C
AQYFK4EEACIDYgAEE4JRzVKskpjByKrZdzId65fnCb0LTKCspV3IrVHc/J0ViaFZ
fjpRIOHv1jHGPhg1ysrimGmmLhYx6KKBgatWYW3EXZGKvAnzqw5jz3kqpNztc4e+
N7ulaVSfHAKycO1no4IBljCCAZIwHwYDVR0jBBgwFoAU4TqrIXzx401UrtRyt/2L
WUIgkFQwHQYDVR0OBBYEFDTq6gzryQra+dDF4u2beMmHnhtsMB0GA1UdJQQWMBQG
CCsGAQUFBwMBBggrBgEFBQcDAjBdBgNVHSAEVjBUMDkGCysGAQQBg44hAQABMCow
KAYIKwYBBQUHAgEWHGh0dHA6Ly9yZXBvc2l0b3J5LmVtc2lnbi5jb20wDQYLKwYB
BAGDjiEBAm4wCAYGZ4EMAQICMHUGCCsGAQUFBwEBBGkwZzAkBggrBgEFBQcwAYYY
aHR0cDovL29jc3AtYy5lbXNpZ24uY29tMD8GCCsGAQUFBzAChjNodHRwOi8vcmVw
b3NpdG9yeS5lbXNpZ24uY29tL2NlcnRzL0VNT1ZUTFNDQUczQy5wN2MwNwYDVR0f
BDAwLjAsoCqgKIYmaHR0cDovL2NybC5lbXNpZ24uY29tLz9yb290dGxzY2FnMy5j
cmwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQAwCgYIKoZIzj0E
AwMDaAAwZQIxAMSZt2xsPeumRdeSMSQ3CbzIZeQ/q7GDCWfeE1Pq+mhgA6gRM44c
NVF3xJ+wsxJk+wIwFJbaDMokD8Ei6eNOiA8yUMYvfzQyngmrhZQMdPCK1SewrR79
4rSb9vGqxZzelQth
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/7485B51C0ED192878FA1D2F948FB529AE1842CC5086C4B67F7BE5B2039DE9489.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDzzCCAregAwIBAgIRAI1aSBGTnvRH13ERzdmEmukwDQYJKoZIhvcNAQELBQAw
ezELMAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4G
A1UEBwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAfBgNV
BAMMGEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczAeFw0yNTA1MTQwMDAwMDBaFw0y
ODEyMzEyMzU5NTlaMEAxCzAJBgNVBAYTAlVTMRQwEgYDVQQKDAtlTXVkaHJhIElu
YzEbMBkGA1UEAwwSRU0gT1YgVExTIENBIC0gRzNDMHYwEAYHKoZIzj0CAQYFK4EE
ACIDYgAEE4JRzVKskpjByKrZdzId65fnCb0LTKCspV3IrVHc/J0ViaFZfjpRIOHv
1jHGPhg1ysrimGmmLhYx6KKBgatWYW3EXZGKvAnzqw5jz3kqpNztc4e+N7ulaVSf
HAKycO1no4IBNTCCATEwHwYDVR0jBBgwFoAUoBEKIz6W8Qfs4q8p74Klf9AwpLQw
HQYDVR0OBBYEFDTq6gzryQra+dDF4u2beMmHnhtsMA4GA1UdDwEB/wQEAwIBBjAS
BgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcD
AjAxBgNVHSAEKjAoMAgGBmeBDAECAjANBgsrBgEEAYOOIQEAATANBgsrBgEEAYOO
IQECbjBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsLmNvbW9kb2NhLmNvbS9B
QUFDZXJ0aWZpY2F0ZVNlcnZpY2VzLmNybDA0BggrBgEFBQcBAQQoMCYwJAYIKwYB
BQUHMAGGGGh0dHA6Ly9vY3NwLmNvbW9kb2NhLmNvbTANBgkqhkiG9w0BAQsFAAOC
AQEAHlbhZpjhkPEAQVhPHRtBDaHqiisVD20pQ1TUeSx3l62Qe7NQ0b7vWQy7DN0i
KOu7BGpP5EnIjvXbz9FhpfPJ4FhKEt3tQ51rqXz2oD8vRaryvExWPobDUz3j7HN6
OzBsVMIe3PD7AAkpky0x8zMSi/ep5R9OMzybmNptbtppyuB5ytgq+h7lQdRIP+CQ
TaJX3qTgfMqzntYre5GljmEB5hU2/rSn8zoSU2APkJidlZFpghtgbD4I2VRHZvCw
FFr/SrFM9pwrgbJNZ1MtyTSVgI5NlNb0aMfLR+/r6jJt3ROeY2yh2QQ2dx+Yqgdb
uL5ChFWOQU+ErSDnUq7yr+pjBQ==
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/432EC25F0D28DE9006D97BF752F17BBB2CD41F669933FCB072D9A1148D0261F3.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDaDCCAu6gAwIBAgIQAIAJkopkEHYBrwX6LxnxCTAKBggqhkjOPQQDAzBWMQsw
CQYDVQQGEwJJTjElMCMGA1UECgwcZU11ZGhyYSBUZWNobm9sb2dpZXMgTGltaXRl
ZDEgMB4GA1UEAwwXZW1TaWduIFJvb3QgVExTIENBIC0gRzMwHhcNMjUwNDMwMTUz
OTMxWhcNNDAwNDI4MTgzMDAwWjBAMQswCQYDVQQGEwJVUzEUMBIGA1UECgwLZU11
ZGhyYSBJbmMxGzAZBgNVBAMMEkVNIEVWIFRMUyBDQSAtIEczQzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABC1W6Cmm+4LGSkaX2WCvlR6QZ66R+SbTQwbaSKiq63hptqZ+
bSdCbgRCqgOzbhmI3/Y2UU7hzwf1uks/8qBmRa59MdWGatMao9JG6wsxd+6Zy3Vm
xRbOdICKZo+R8MR/yqOCAZUwggGRMB8GA1UdIwQYMBaAFOE6qyF88eNNVK7Ucrf9
i1lCIJBUMB0GA1UdDgQWBBSmJV6AqU2385Z8G8eR35K87kvrXzAdBgNVHSUEFjAU
BggrBgEFBQcDAQYIKwYBBQUHAwIwXAYDVR0gBFUwUzA5BgsrBgEEAYOOIQEAATAq
MCgGCCsGAQUFBwIBFhxodHRwOi8vcmVwb3NpdG9yeS5lbXNpZ24uY29tMA0GCysG
AQQBg44hAQJ4MAcGBWeBDAEBMHUGCCsGAQUFBwEBBGkwZzAkBggrBgEFBQcwAYYY
aHR0cDovL29jc3AtYy5lbXNpZ24uY29tMD8GCCsGAQUFBzAChjNodHRwOi8vcmVw
b3NpdG9yeS5lbXNpZ24uY29tL2NlcnRzL0VNRVZUTFNDQUczQy5wN2MwNwYDVR0f
BDAwLjAsoCqgKIYmaHR0cDovL2NybC5lbXNpZ24uY29tLz9yb290dGxzY2FnMy5j
cmwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQAwCgYIKoZIzj0E
AwMDaAAwZQIwBy1wTnzH4lXDTy2PD91ysLjvnlVN3JbJmc1BIMEU8TOLkYVHibMc
9HeyonikFSfmAjEA6uE3QRxlrZTz/1/lXPTEMUhoauAtycagtlNFp79kjhvNa2/f
Aal1GNxsOutLnr0Y
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/FD9D5C2DBBD4995AB69B8D50C439D9527B00529199C2FD01B2174EB58F07021F.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDzTCCArWgAwIBAgIQBfB4dS3s56G7hZXTAxZxcTANBgkqhkiG9w0BAQsFADB7
MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVyMRAwDgYD
VQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEhMB8GA1UE
AwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTI1MDUxNDAwMDAwMFoXDTI4
MTIzMTIzNTk1OVowQDELMAkGA1UEBhMCVVMxFDASBgNVBAoMC2VNdWRocmEgSW5j
MRswGQYDVQQDDBJFTSBFViBUTFMgQ0EgLSBHM0MwdjAQBgcqhkjOPQIBBgUrgQQA
IgNiAAQtVugppvuCxkpGl9lgr5UekGeukfkm00MG2kioqut4abamfm0nQm4EQqoD
s24ZiN/2NlFO4c8H9bpLP/KgZkWufTHVhmrTGqPSRusLMXfumct1ZsUWznSAimaP
kfDEf8qjggE0MIIBMDAfBgNVHSMEGDAWgBSgEQojPpbxB+zirynvgqV/0DCktDAd
BgNVHQ4EFgQUpiVegKlNt/OWfBvHkd+SvO5L618wDgYDVR0PAQH/BAQDAgEGMBIG
A1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMC
MDAGA1UdIAQpMCcwBwYFZ4EMAQEwDQYLKwYBBAGDjiEBAAEwDQYLKwYBBAGDjiEB
AngwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybC5jb21vZG9jYS5jb20vQUFB
Q2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNAYIKwYBBQUHAQEEKDAmMCQGCCsGAQUF
BzABhhhodHRwOi8vb2NzcC5jb21vZG9jYS5jb20wDQYJKoZIhvcNAQELBQADggEB
AIFfHiaMSjnrdZygRYV4ekRBmG7ybcFk4hGQWMMyMFi0cAEk2+dGfz5bl8IaIbLq
z+uVJzhOgVEX7WqIfgbWfFsfPYHYjPHBmy7SlZ3BwA86IQ6qF/etpX2/qL9A5yRN
N3nVowUpaqV6H3aCpkAh3wR2ZNkvAbLDvPz3J0l+sEWjWv+ZISOV4R+hXDTdPXV0
1lKxnbwqEsdo/sE2QkCDKwFrZh/0uKjWspydJj+jSaDLTrGNx50Dgmn7VEcD1ZI5
FXjknVUiO25YlmS1dtVZSBbyUKSjlrP/yDwPcZunoAsmCAAtCKsFLviLaymzvsKI
eSSDGxpSySp2VCxompGDk8g=
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/9E39DE2881273ACC225A149C72BA3E0F51424963669AB633EE1DC7DF5DB067B4.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDWzCCAuCgAwIBAgIPeBiTP4+FtGGaKzX7qD0KMAoGCCqGSM49BAMDMFUxCzAJ
BgNVBAYTAklOMSUwIwYDVQQKDBxlTXVkaHJhIFRlY2hub2xvZ2llcyBMaW1pdGVk
MR8wHQYDVQQDDBZlbVNpZ24gUm9vdCBDUyBDQSAtIEczMB4XDTI1MDQzMDE2MDgy
N1oXDTQwMDQyODE4MzAwMFowPjELMAkGA1UEBhMCTkwxEzARBgNVBAoMCmVNdWRo
cmEgQlYxGjAYBgNVBAMMEUVNIE9WIENTIENBIC0gRzNCMHYwEAYHKoZIzj0CAQYF
K4EEACIDYgAEqrsPsGZqz88B+tUr/P1MK/LLPDSX3nOVDlgZth/mlQmHQcjEkUOb
NKBDHK/+W/m0wcjorgAB+fTcitgsWfNjnpbNbD1NsM7+wmw9YlF7N3YTcnQ/jord
d7EAZPKr5eBQo4IBizCCAYcwHwYDVR0jBBgwFoAUaHQD+IXKjVRQVx0W4MjeRQ2r
zS0wHQYDVR0OBBYEFHn66OzP2w11jaRY1p+27dx8Sd7mMBMGA1UdJQQMMAoGCCsG
AQUFBwMDMF4GA1UdIARXMFUwOQYLKwYBBAGDjiEBAAEwKjAoBggrBgEFBQcCARYc
aHR0cDovL3JlcG9zaXRvcnkuZW1zaWduLmNvbTAOBgwrBgEEAYOOIQECgUgwCAYG
Z4EMAQQBMHQGCCsGAQUFBwEBBGgwZjAkBggrBgEFBQcwAYYYaHR0cDovL29jc3At
Yi5lbXNpZ24uY29tMD4GCCsGAQUFBzAChjJodHRwOi8vcmVwb3NpdG9yeS5lbXNp
Z24uY29tL2NlcnRzL0VNT1ZDU0NBRzNCLnA3YzA2BgNVHR8ELzAtMCugKaAnhiVo
dHRwOi8vY3JsLmVtc2lnbi5jb20vP3Jvb3Rjc2NhZzMuY3JsMA4GA1UdDwEB/wQE
AwIBBjASBgNVHRMBAf8ECDAGAQH/AgEAMAoGCCqGSM49BAMDA2kAMGYCMQC/zr03
YEELsNKqzUtH2dVFi4BaKFdyrr/6G1dIWp8KAVgsw2/u4lyyboUDaC9jDvICMQC9
HTxku84tNX9dmHOtH7aC2Nu/JM0jTf6KjZAvovCJzzv1IFWSZpVLZibynMLXOrM=
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/A496E23AC0CAB8155FC9B117B97EAE368EFCBB9041AEC8804D5A308D2D01C2D8.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDwzCCAqugAwIBAgIQQeMrc6wYXWzg10gLrPhOaTANBgkqhkiG9w0BAQsFADB7
MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVyMRAwDgYD
VQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEhMB8GA1UE
AwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTI1MDUxNDAwMDAwMFoXDTI4
MTIzMTIzNTk1OVowPjELMAkGA1UEBhMCTkwxEzARBgNVBAoMCmVNdWRocmEgQlYx
GjAYBgNVBAMMEUVNIE9WIENTIENBIC0gRzNCMHYwEAYHKoZIzj0CAQYFK4EEACID
YgAEqrsPsGZqz88B+tUr/P1MK/LLPDSX3nOVDlgZth/mlQmHQcjEkUObNKBDHK/+
W/m0wcjorgAB+fTcitgsWfNjnpbNbD1NsM7+wmw9YlF7N3YTcnQ/jordd7EAZPKr
5eBQo4IBLDCCASgwHwYDVR0jBBgwFoAUoBEKIz6W8Qfs4q8p74Klf9AwpLQwHQYD
VR0OBBYEFHn66OzP2w11jaRY1p+27dx8Sd7mMA4GA1UdDwEB/wQEAwIBBjASBgNV
HRMBAf8ECDAGAQH/AgEAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMDIGA1UdIAQrMCkw
CAYGZ4EMAQQBMA0GCysGAQQBg44hAQABMA4GDCsGAQQBg44hAQKBSDBDBgNVHR8E
PDA6MDigNqA0hjJodHRwOi8vY3JsLmNvbW9kb2NhLmNvbS9BQUFDZXJ0aWZpY2F0
ZVNlcnZpY2VzLmNybDA0BggrBgEFBQcBAQQoMCYwJAYIKwYBBQUHMAGGGGh0dHA6
Ly9vY3NwLmNvbW9kb2NhLmNvbTANBgkqhkiG9w0BAQsFAAOCAQEAIh0OzWsdBYhY
7+yxPGyosRL+uUSN6/Mrd30fBuougs5FVWQ3cRgLhImnUUgXADY9buugWhMmfT3c
yU5T1MFXZXClCILm5mfg+oqm/ikUWJl3Ayf2GvYf2O++6vzqvkn418nI5Lpdt0O7
Li524YS/3CZHDA+zZQ7rrHpZXgQ9Hmp8AUQ4FneaGjNanFoYxiZxwCyW5z4u7AoK
0bmOVqKtcDFoVNz5++G9TYDJdhWOXmKKgzqRo1MK0PjazNT7MGHqknP93SqMVJ1g
mX/qNWxYteAjlvFanQxBNX/+TRxDjuFsEHO/7BvqSpIIck0UEEfizhN8zNpWLbcl
EqVgl0g39A==
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/4B2460A466F95FD40113BCDCCA2CEB29B3B093921DE45474DA7DF48874C630B1.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDWzCCAuGgAwIBAgIPVEt/kiwxriIKSpIpFvbmMAoGCCqGSM49BAMDMFUxCzAJ
BgNVBAYTAklOMSUwIwYDVQQKDBxlTXVkaHJhIFRlY2hub2xvZ2llcyBMaW1pdGVk
MR8wHQYDVQQDDBZlbVNpZ24gUm9vdCBDUyBDQSAtIEczMB4XDTI1MDQzMDE2Mzg0
MFoXDTQwMDQyODE4MzAwMFowPzELMAkGA1UEBhMCVVMxFDASBgNVBAoMC2VNdWRo
cmEgSW5jMRowGAYDVQQDDBFFTSBPViBDUyBDQSAtIEczQzB2MBAGByqGSM49AgEG
BSuBBAAiA2IABLnw4GNHAqacpqrdRDz9YsQbm6SyCSRpfXl052kaEm+5avs+NML9
O8X0gwYfJl3CpYQ2NHMjUQQ2so8E84YjYwZ5gOJQPgJTLWVGI1pxZaJZoe9Jb3Qb
X97neHII5Lj676OCAYswggGHMB8GA1UdIwQYMBaAFGh0A/iFyo1UUFcdFuDI3kUN
q80tMB0GA1UdDgQWBBTub3MpjW+/p7Mbw5U09hVWRHhmtzATBgNVHSUEDDAKBggr
BgEFBQcDAzBeBgNVHSAEVzBVMDkGCysGAQQBg44hAQABMCowKAYIKwYBBQUHAgEW
HGh0dHA6Ly9yZXBvc2l0b3J5LmVtc2lnbi5jb20wDgYMKwYBBAGDjiEBAoFIMAgG
BmeBDAEEATB0BggrBgEFBQcBAQRoMGYwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3Nw
LWMuZW1zaWduLmNvbTA+BggrBgEFBQcwAoYyaHR0cDovL3JlcG9zaXRvcnkuZW1z
aWduLmNvbS9jZXJ0cy9FTU9WQ1NDQUczQy5wN2MwNgYDVR0fBC8wLTAroCmgJ4Yl
aHR0cDovL2NybC5lbXNpZ24uY29tLz9yb290Y3NjYWczLmNybDAOBgNVHQ8BAf8E
BAMCAQYwEgYDVR0TAQH/BAgwBgEB/wIBADAKBggqhkjOPQQDAwNoADBlAjEA8yPg
8sntOhLwV2QXJ5LEaKSpo/fnE3uOgTadK73fDhyjiqr0Io9GVuQTYqBPbQ2TAjBg
euApmBS486+iei03lRrp139dPw6k28jjGNvWsAU7A1N86J1zPJVDEyVH+nMAWC0=
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
    cat > "$EM_WORK/certs/84112972B8E59D14560AE7E7119654474AAD119990CF3722BFC1E3B91615E1FD.pem" <<'EMUDHRA_CERTIFICATE' || return 2
-----BEGIN CERTIFICATE-----
MIIDxTCCAq2gAwIBAgIRANal72E7OQ8y75zfNJ93KEEwDQYJKoZIhvcNAQELBQAw
ezELMAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4G
A1UEBwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAfBgNV
BAMMGEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczAeFw0yNTA1MTQwMDAwMDBaFw0y
ODEyMzEyMzU5NTlaMD8xCzAJBgNVBAYTAlVTMRQwEgYDVQQKDAtlTXVkaHJhIElu
YzEaMBgGA1UEAwwRRU0gT1YgQ1MgQ0EgLSBHM0MwdjAQBgcqhkjOPQIBBgUrgQQA
IgNiAAS58OBjRwKmnKaq3UQ8/WLEG5uksgkkaX15dOdpGhJvuWr7PjTC/TvF9IMG
HyZdwqWENjRzI1EENrKPBPOGI2MGeYDiUD4CUy1lRiNacWWiWaHvSW90G1/e53hy
COS4+u+jggEsMIIBKDAfBgNVHSMEGDAWgBSgEQojPpbxB+zirynvgqV/0DCktDAd
BgNVHQ4EFgQU7m9zKY1vv6ezG8OVNPYVVkR4ZrcwDgYDVR0PAQH/BAQDAgEGMBIG
A1UdEwEB/wQIMAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwMgYDVR0gBCsw
KTAIBgZngQwBBAEwDQYLKwYBBAGDjiEBAAEwDgYMKwYBBAGDjiEBAoFIMEMGA1Ud
HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBCwUAA4IBAQBgGbZ+NDkn
2Fr5dCVs/51+6cT5iEPP1stglX4TI2UaNh9LmPdltxXw3crV8gK5L8i+d+ScGibF
y0obtBHNTldXDgLnAHIzY3n+pceyKj7O2ae9CYnyuu5RBifeI3XYKowWE+oXnVGF
Oy0CvCJ/JsdP6aYgoCa9hGnAYicYQQL6MOMQZ5PuhcSM8t4giIzrpgrEkUP93GYE
emDG5Z8BYwKs80lLeQNBnwg/VHJ3iEF/o84RXYwrlrKqJ+33C094o6LNikMJCqOK
/WYHZSR8Xyhf8GXFAj5pZuI6Bcpug2V/E7i42j8OBhc25aNYDqK+B0qmb90sjNUB
g3tJeSIb/599
-----END CERTIFICATE-----
EMUDHRA_CERTIFICATE
}

# EMUDHRA_MAIN
em_main "$@"
exit $?
