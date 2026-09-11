# OSINT

A passive OSINT tool for Android, covering four jobs:

| Module | What it answers | Keys needed |
|---|---|---|
| **Recon** | What does this domain's attack surface look like? DNS records, hosts from Certificate Transparency, service banners. | None (Shodan optional) |
| **Threat intel** | Is this indicator known-bad? Reputation for a domain, IP, URL or file hash. | VirusTotal and/or AbuseIPDB |
| **Brand** | Is anyone impersonating us? Generates look-alike domains and checks which are registered. | None |
| **Due diligence** | Who is behind this domain? Registration record, DNS and mail posture, certificate footprint. | None |

Three of the four modules work with no API key at all.

## Scope: passive only

Every source is read second-hand — public DNS resolvers, Certificate
Transparency logs, registry RDAP endpoints, and third-party reputation
databases. **No traffic is ever sent to the target under investigation.** There
is no port scanning, probing, or exploitation capability here, by design: it
keeps the tool usable for third-party assessment without authorisation to scan
the target, and it means a lookup leaves no trace in the target's logs.

The flip side is that findings are **leads, not conclusions**:

- Certificate Transparency hosts may have been decommissioned years ago.
- Shodan banners are historical, from whenever Shodan last scanned.
- Shodan's CVE list is inferred from version strings, not confirmed exploitable.
- A clean reputation verdict is not evidence of safety — coverage varies wildly
  between feeds, and a miss is far commoner than a false hit.

Aimed at infrastructure and organisations: your own estate, assets you are
authorised to assess, brand impersonation, and counterparty checks.

## Layout

Two packages, split so that the logic is testable without a device:

```
osint/
├── osint_core/     Pure Dart. Every source, model and repository. 95 tests.
└── osint_app/      Flutter Android UI. MVVM over osint_core. 18 tests.
```

`osint_core` has no Flutter dependency, so it runs under plain `dart test` and
could be reused by a CLI or a server without change.

The app follows the layering in
[`flutter-apply-architecture-best-practices`](../skills/flutter-apply-architecture-best-practices/SKILL.md):
services wrap one API each, repositories compose services and return domain
models, view models hold UI state as `ChangeNotifier`s, and views only render.

## Sources

| Source | Used for | Key | Notes |
|---|---|---|---|
| DNS-over-HTTPS (Cloudflare) | A/AAAA/NS/MX/TXT/SOA/CAA/CNAME | No | Chosen over UDP DNS: no native sockets, and survives networks that hijack port 53 |
| crt.sh | Certificate history, subdomain discovery | No | Slow and rate-limits hard; queried once per target |
| RDAP (rdap.org) | Registration, registrar, dates, DNSSEC | No | The structured successor to WHOIS |
| VirusTotal v3 | Reputation for domain/IP/hash | Yes | Free tier: 4 lookups/minute |
| AbuseIPDB | IP abuse reports | Yes | Free tier: daily quota |
| Shodan | Host ports, banners, CVE leads | Yes | Costs one credit per address |

API keys are stored in the Android keystore via `flutter_secure_storage`
(`EncryptedSharedPreferences`), are never read back into the UI once saved, and
are sent only to the source they belong to.

## Running it

Needs the Flutter SDK and the Android SDK.

```bash
cd osint/osint_app
flutter pub get
flutter run                 # on a connected device or emulator
flutter build apk --release
```

Tests:

```bash
cd osint/osint_core && dart test        # 95 tests, no network
cd osint/osint_app  && flutter test     # 18 tests, no network
```

Every test uses `MockClient`, so the suites never touch the internet and are
safe to run in CI. To check a real source's response format by hand:

```bash
cd osint/osint_core
dart run example/live_smoke.dart anthropic.com
```

## Design notes

**Partial failure is the normal case.** OSINT fans out across independent
sources, and one missing key or dead endpoint must not discard everything else.
Every service returns a `SourceResult` — success, empty, or failure — instead of
throwing, and each report carries per-source `SourceNote`s that the UI renders
alongside the data. A thin result is therefore never mistaken for a clean one.

**"Nothing found" and "lookup failed" are kept strictly apart.** In the brand
sweep this is the load-bearing safety property: a rate-limited DNS lookup is
reported as unknown, never as "not registered". Turning a rate limit into a
false all-clear would be the most damaging wrong answer the tool could give.

**The sweep is bounded and staged.** Candidate generation is local and free, so
the UI shows the candidate count and lets the user pick a limit before any
request is made. Checks then run through a fixed concurrency window rather than
all at once, which would get the device rate-limited and starve the UI.
