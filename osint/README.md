# OSINT

A passive OSINT tool for Android, covering four jobs:

| Module | What it answers | Keys needed |
|---|---|---|
| **Recon** | What does this domain's attack surface look like? DNS, hosts from Certificate Transparency, passive DNS, archived URLs, service banners. | None (Shodan optional) |
| **Threat intel** | Is this indicator known-bad? Reputation across APIs plus membership in bulk public blocklists. | None (VirusTotal/AbuseIPDB optional) |
| **Brand** | Is anyone impersonating us? Two sweeps: misspellings of the name, and the name across every registrable namespace. | None |
| **Due diligence** | Who is behind this domain? Registration record, DNS and mail posture, certificate footprint. | None |

Every module works with no API key. Keys only add VirusTotal, AbuseIPDB and Shodan.

## How many sources

The in-app **Sources** screen fetches this live and shows it. A run on
2026-09-12 reported:

```
    590  RDAP registry servers            IANA RDAP bootstrap
     45  Certificate Transparency logs    CT log list
      9  Threat feeds                     Bundled registry
      9  API integrations                 Bundled
  10325  Public suffixes                  Public Suffix List
   1438  Top-level domains                IANA TLD list

queryable sources : 653
namespaces        : 11763
catalogue total   : 12416
feed entries      : 51541
```

Two totals, deliberately kept apart. Merging them would make a better headline
and a worse tool:

- **Queryable sources (653)** answer a question: registry servers, CT logs,
  threat feeds, API clients.
- **Namespaces (11,763)** are places a domain can be registered, and so places
  a brand can be squatted. They are sweep targets, not data sources.

Every count is enumerated from a list published by the body that governs it, so
each can be checked against the source rather than taken on trust. Nothing here
is asserted. Run it yourself:

```bash
cd osint/osint_core
dart run example/catalog_count.dart
```

The numbers move between runs — CT logs went 42 to 45 in a day, and the feed
corpus from 46k to 51k entries. That is why the catalogue is fetched rather
than baked in.

### Why not 10,000 hand-written API clients

Because there are not 10,000 OSINT APIs, and a tool claiming otherwise is
either counting scraped web pages that break within the month, or counting the
same data several times over. The sources that genuinely number in the
thousands are the registries: every TLD runs its own RDAP server, and every
public suffix is a real namespace a squatter can register in. Those are
enumerated here, and used.

## Scope: passive only

Every source is read second-hand — public resolvers, Certificate Transparency
logs, registry RDAP endpoints, archived crawls, and third-party reputation
databases. **No traffic is ever sent to the target under investigation.** There
is no port scanning, probing, or exploitation capability, by design: it keeps
the tool usable for third-party assessment without authorisation to scan, and a
lookup leaves nothing in the target's logs.

Findings are **leads, not conclusions**:

- Certificate Transparency hosts may have been decommissioned years ago.
- Shodan banners are historical; its CVE list is inferred from version strings.
- Blocklist membership ranges from "criminal-controlled netblock" to "attacked
  someone's SSH last week and has since been cleaned". Feeds carry a severity
  so a Tor exit never reads like a Spamhaus DROP listing.
- A clean verdict is not evidence of safety — coverage varies wildly between
  feeds, and a miss is commoner than a false hit.

Aimed at infrastructure and organisations: your own estate, assets you are
authorised to assess, brand impersonation, and counterparty checks.

## Layout

```
osint/
├── osint_core/     Pure Dart. Every source, model and repository. 177 tests.
└── osint_app/      Flutter Android UI. MVVM over osint_core. 35 tests.
```

`osint_core` has no Flutter dependency, so it runs under plain `dart test` and
could back a CLI or a server unchanged.

The app follows the layering in
[`flutter-apply-architecture-best-practices`](../skills/flutter-apply-architecture-best-practices/SKILL.md):
services wrap one API each, repositories compose services and return domain
models, view models hold UI state as `ChangeNotifier`s, and views only render.

## Sources in detail

**Keyless**

| Source | Used for |
|---|---|
| DNS-over-HTTPS (Cloudflare) | A/AAAA/NS/MX/TXT/SOA/CAA/CNAME |
| crt.sh | Certificate history, host discovery |
| RDAP (rdap.org) | Registration, registrar, dates, DNSSEC |
| AlienVault OTX | Community threat pulses, passive DNS |
| HackerTarget | Host discovery, reverse IP |
| Wayback Machine | Archived URLs and forgotten paths |
| 9 bulk threat feeds | IPv4 blocklist membership |
| IANA / Mozilla registries | The namespace and endpoint catalogue |

**Keyed** — VirusTotal (4 lookups/minute free), AbuseIPDB (daily quota), Shodan
(one credit per address).

API keys are stored in the Android keystore via `flutter_secure_storage`
(`EncryptedSharedPreferences`), are never read back into the UI once saved, and
are sent only to the source they belong to.

## Running it

Needs the Flutter SDK and the Android SDK.

```bash
cd osint/osint_app
flutter pub get
flutter run
flutter build apk --release
```

Tests — 212 in total, none of which touch the network:

```bash
cd osint/osint_core && dart test
cd osint/osint_app  && flutter test
```

Live checks against the real services, for when a response format is suspected
to have changed:

```bash
cd osint/osint_core
dart run example/live_smoke.dart anthropic.com
dart run example/catalog_count.dart
```

## Design notes

**Partial failure is the normal case.** One missing key or dead endpoint must
not discard everything else. Every service returns a `SourceResult` — success,
empty, or failure — instead of throwing, and each report carries per-source
`SourceNote`s the UI renders alongside the data. A thin result is never
mistaken for a clean one.

**"Nothing found" and "lookup failed" are kept strictly apart.** In the sweeps
this is load-bearing: a rate-limited DNS lookup reports as unknown, never as
"not registered". In the blocklist check, a feed that failed to download is
reported as such, on screen, in those words — turning a failed fetch into a
false all-clear would be the most damaging wrong answer available.

**Host discovery is a union, not a single source.** CT only knows hosts issued
a certificate; HackerTarget only hosts seen in DNS; passive DNS only hosts that
resolved at some point in the past. They disagree often enough that running all
three materially widens the surface found. Hosts outside the target domain are
discarded — shared certificates and shared hosting both return unrelated names,
and attributing those to the target would be wrong.

**Feeds are fetched whole and searched locally,** because they are published as
flat files with no query API. They are cached for six hours: the lists rebuild
hourly at best, and re-downloading megabytes per indicator would be slow and
rude to the volunteers hosting them. Membership uses real CIDR arithmetic, not
string matching — Spamhaus lists /24s and larger, so textual comparison would
miss every address in a listed block but the network address itself.

**Sweeps are bounded and staged.** Candidate generation is local and free, so
the UI shows the count and lets the user pick a limit before any request is
made. Checks then run through a fixed concurrency window rather than all at
once, which would get the device rate-limited and starve the UI.
