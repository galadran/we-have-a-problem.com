# Read-only eMudhra trust-store audits

These scripts inspect selected local trust stores using the public certificate
inventory in this repository. They do not remove certificates, install explicit
blocks, rebuild trust stores, install packages or change execution policy.
Updating operating systems, browsers and affected packages remains the preferred
action; see the [incident page](https://emudhra.we-have-a-problem.com/#users).

Copy the audit file for your platform. Each file is standalone and embeds its
certificate data; Python, this repository and JSON sidecars are not needed to run
it. The embedded snapshot comes from `roots.json` and
`impacted-intermediates.json` at commit
`bb7c2a87c5f9157ad83dd8ac32ae90a7e3205274`.

## Interpret the results

- **PASS** (green): the particular check completed without an observation. This
  does not establish overall host safety.
- **WARN** (yellow): a listed issuer root is present, or an exact intermediate
  lacks an explicit local deny in the selected native policy. Vendor revocation
  controls may already protect the client. A warning is **not proof of
  vulnerability** or a recommendation to remove a root.
- **ERROR** (red): inspection was incomplete, for example because a file could
  not be read, a tool failed or certificate data was malformed.
- **INFO** (cyan): scope, summary or an optional live-probe observation.

Exit codes are **0** for completed selected checks without observations, **1**
for observations, and **2** for incomplete inspection or an operational error.
Errors take precedence over observations. Review the messages before taking
action; do not interpret exit 1 as an exploitability verdict.

## Linux and macOS

Requirements: Bash 3.2 or newer, OpenSSL or LibreSSL, and standard system
utilities. Run the file directly or use `bash -p`; `-p` prevents inherited shell
startup configuration from being loaded. The scripts need no elevated access
when the selected stores are readable. Native macOS policy inspection also
requires `security` and a `plutil` supporting `-extract raw -expect`.

From the repository root:

```sh
# Default Linux system PEM bundles
bash -p ./scripts/emudhra-linux-audit.sh

# Default macOS system/Homebrew PEM bundles and administrative trust settings
bash -p ./scripts/emudhra-mac-audit.sh

# Inspect a specific readable PEM bundle, including a certifi or application bundle
bash -p ./scripts/emudhra-linux-audit.sh --bundle /path/to/cacert.pem
bash -p ./scripts/emudhra-mac-audit.sh --bundle /path/to/cacert.pem

# Inspect an existing Java keystore using keytool and the conventional password changeit
bash -p ./scripts/emudhra-linux-audit.sh --java-keystore /path/to/cacerts

# Optional network observations against the incident's twelve TLS test hosts
bash -p ./scripts/emudhra-mac-audit.sh --probe
```

`--bundle` and `--java-keystore` are repeatable. Supplying either restricts
inspection to the explicitly named stores and skips the default scope. No
recursive application, virtual-environment or Java installation search is
performed. Java inspection requires an available `keytool`; an unsupported
password or an unreadable/unrecognized entry is an error.

The default Linux paths are `/etc/ssl/certs/ca-certificates.crt`,
`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`,
`/var/lib/ca-certificates/ca-bundle.pem` and `/etc/ssl/cert.pem`, when present.
The default macOS paths are `/etc/ssl/cert.pem` and the
`etc/ca-certificates/cert.pem` and `etc/openssl@3/cert.pem` bundles beneath
`/opt/homebrew` and `/usr/local`, when present. Readable file symlinks are followed;
unreadable or broken links report errors.

PEM and Java checks report exact DER SHA-256 matches for the four issuers in
`roots.json`: emSign Root TLS CA - G3, emSign Root CS CA - G3, AAA Certificate
Services and emSign ECC Root CA - G3. This is an inventory of possible chain
issuers, **not a recommendation to distrust all four roots**. Both ordinary and
OpenSSL trusted-certificate PEM blocks are inspected; malformed, truncated,
noncanonical, trailing-DER or NUL-containing input reports incomplete inspection.

The macOS native check reads administrative trust settings and looks for global
explicit denies covering the 16 exact intermediate certificate variants.
Application- or policy-constrained denies do not count as global denies. This
does not inspect Apple's separate vendor-distributed blocking mechanisms, other
users' policy or every application trust engine. Missing explicit administrative
denies do not mean Apple's protections are absent.

Audits are offline by default. `--probe` contacts the twelve incident test hosts
with bounded timeouts. Its output describes acceptance or certificate rejection
of the chain currently served; it does not establish a pinned affected chain,
identify the rejection cause or change the local inventory observations. Other
network errors make the run incomplete. Use the site's offline chain material
for separate client verification when appropriate.

The scripts create private temporary files under `/tmp` for parsing and policy
export, and remove them at exit. Selected trust stores are opened only for
reading. They do not require or invoke Python.

## Windows

Use Windows PowerShell 5.1 or PowerShell 7 on Windows. The script runs offline,
uses .NET `X509Store` and does not self-elevate. It reads an existing store with
`ReadOnly | OpenExistingOnly`; it never opens a writable store or creates one.

```powershell
# Inspect machine-wide explicit blocks (the default scope)
.\scripts\emudhra-windows-audit.ps1

# Inspect only the current account's explicit blocks
.\scripts\emudhra-windows-audit.ps1 -Scope CurrentUser

# Structured output
.\scripts\emudhra-windows-audit.ps1 -AsJson
$LASTEXITCODE
```

The script checks for the 16 exact intermediate variants in the selected
**Disallowed** store. The default is `LocalMachine`; `CurrentUser` is a separate
scope, and the script does not combine the two. The report includes the scope,
certificate SHA-256 and native thumbprint, `PresentBefore`,
`ExplicitlyBlocked`, status and errors. JSON contains no color formatting.

Only the precise native file-not-found result is treated as an absent store;
other access or inspection failures are errors. An absent store means the local
explicit blocks were not found, which produces observations. Microsoft or other
vendor protections may already block the intermediates without these entries.
The script does not inspect vendor CTL freshness, other accounts, Firefox,
Java, Git/OpenSSL, certifi, WSL, containers or application-specific stores.

## Colors and platform coverage

Colors activate automatically for interactive terminal output. Redirected
output and the presence of `NO_COLOR` suppress automatic color. Explicit modes
are available:

```sh
bash -p ./scripts/emudhra-mac-audit.sh --color never
bash -p ./scripts/emudhra-linux-audit.sh --color always
```

```powershell
.\scripts\emudhra-windows-audit.ps1 -Color Never
```

The shell entry points have been exercised on macOS Bash 3.2/LibreSSL with
disposable PEM and Java fixtures. Windows policy handling has been exercised
with mocked stores under PowerShell 7. Native Linux execution and Windows
PowerShell 5.1/7 store inspection still need target-platform validation.
No system trust policy was changed during local validation.
