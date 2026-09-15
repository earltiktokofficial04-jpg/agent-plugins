# Source licensing and access

Written after a research pass on 2026-09-14/15 that checked every source
against its *current* terms rather than its documentation. Much OSINT writing
from 2023 is now wrong about which sources need a key, and — more dangerous for
anyone shipping — about which permit commercial use.

**If this tool is ever sold, bundled into a paid service, or made
ad-supported, read this file first.** Several sources it already queries
restrict the free tier to non-commercial use. That is a licensing question, not
a technical one, and no amount of code changes it.

## Integrated today

| Source | Key | Commercial use | Notes |
|---|---|---|---|
| Cloudflare DNS-over-HTTPS | No | Permitted | Public resolver |
| crt.sh (Sectigo) | No | Not stated | Rate-limits hard; query once per target |
| RDAP — IANA bootstrap + registry servers | No | Permitted | Registry data is public by policy |
| IANA TLD list, Public Suffix List, CT log list | No | Permitted | PSL is MPL-2.0 |
| AlienVault OTX | No (keyless endpoints) | Check before selling | LevelBlue terms |
| HackerTarget | No | **Free tier is non-commercial** | Quota enforced per source IP |
| Wayback Machine CDX | No | Permitted | Internet Archive terms |
| **Team Cymru IP-to-ASN** | No | **Not stated** | "Free, forever" community service; ask them before commercial use |
| **Shodan InternetDB** | No | Check Shodan terms | Free tier of a commercial product |
| Spamhaus DROP | No | **Non-commercial** | Commercial use needs a Spamhaus licence |
| Feodo Tracker, SSLBL (abuse.ch) | No (bulk files) | **Non-commercial** | See the abuse.ch note below |
| Emerging Threats, CINS, GreenSnow, DShield, blocklist.de | No | Varies — check each | None verified as commercial-clear |
| Tor bulk exit list | No | Permitted | Public by design |
| VirusTotal, AbuseIPDB, Shodan (paid API) | User-supplied | Per the user's own plan | Key never leaves the device |

## The abuse.ch change, and what it means for code already shipped

Since **30 June 2025** the abuse.ch *query* APIs — URLhaus, MalwareBazaar,
ThreatFox, YARAify — require an `Auth-Key`, verified live: an unauthenticated
POST returns `401 {"error":"Unauthorized"}`. The key is free but obtainable only
through OAuth sign-in with X, Google, LinkedIn or GitHub, so it is per-user and
cannot be shipped inside an APK.

The **static bulk flat files remain keyless** and current, which is why the
Feodo Tracker and SSLBL feeds this tool already downloads still work. That is
the integration path that survives.

The catch: abuse.ch's terms restrict free access to *not-for-profit purposes*,
with commercial use routed to a paid Spamhaus subscription. The wording is
written around authenticated users, so whether it binds anonymous bulk
downloads is genuinely ambiguous — but the ambiguity runs against a commercial
deployment, not for it.

## Considered and rejected

**RIPEstat** is the richest keyless source found — ASN, BGP state, routing
history, announced prefixes, abuse contacts, and city-level geolocation, all
from one JSON API with no key. It was not integrated because RIPE NCC's terms
(Art. 3.3) forbid *"incorporating the RIPEstat Data with other sources of data
and packaging it as commercial product"* without written permission. That
sentence describes a multi-source OSINT aggregator precisely. Team Cymru covers
the ASN gap instead, over DNS the tool already speaks.

If this stays a free, non-commercial tool, RIPEstat is permitted and worth
adding — its terms allow network analysis, monitoring and research. Written
permission for anything else: `stat@ripe.net`.

**ip-api.com** was rejected twice over: its free endpoint is cleartext HTTP
only, which Android blocks by default, and its terms prohibit commercial use.

**OpenCorporates** now returns `401 Invalid Api Token`. No longer open.

## Worth adding, not yet integrated

**IPtoASN bulk TSV** — `https://iptoasn.com/data/ip2asn-combined.tsv.gz`, ~9MB
gzipped, rebuilt hourly, and **PDDL 1.0 public domain**: the only ASN source
found with an unambiguous commercial-use grant. Its live per-IP API has been
dead since December 2020, so it must be shipped or cached and resolved locally.
The right answer if this ever needs to work offline or be sold.

**PhishTank** — `https://data.phishtank.com/data/online-valid.csv`, keyless,
~76k live entries, and explicitly free for commercial use, which makes it rare
here. Two integration traps established by the research: an un-cache-busted
request can receive a Cloudflare-cached redirect carrying an expired signature
that resolves to a **404 placeholder JPEG**, so the client must cache-bust and
validate `Content-Type` or it will silently ingest an image as a feed. And
`developer_info.php` (bulk dumps, keyless) is not `api_info.php` (lookup API,
key required). Registration for the optional rate-limit key has been closed
since 2020, so keyless is the only path.

**GLEIF LEI** — `https://api.gleif.org/api/v1/lei-records`, keyless, verified
live with a golden copy dated the same day. The research round did not examine
it; a direct probe did. Fills the company-registry gap.

**Have I Been Pwned** — `/api/v3/breaches` (the breach *catalogue*) is keyless;
`/api/v3/breachedaccount` returns `401 missing hibp-api-key`. Probed directly;
the research round left this question open.

## Gaps still open

Passive DNS beyond OTX's patchy keyless coverage, and company registry data for
Malaysia and ASEAN specifically, have no verified keyless source yet.

Mail-security posture — SPF, DMARC policy, MTA-STS, DANE — needs no new source
at all: it is TXT and TLSA lookups over the DNS-over-HTTPS transport already
integrated. That is logic to write, not a source to find.
