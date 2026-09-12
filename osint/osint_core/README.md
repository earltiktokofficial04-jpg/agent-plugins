# osint_core

The passive OSINT engine: every source, model and repository, as pure Dart with
no Flutter dependency. See [../README.md](../README.md) for the project
overview, scope and source list.

## Shape

```
lib/src/
├── models/         Target, DnsRecord, CtCertificate, DomainRegistration,
│                   IocVerdict, typosquat types, threat feeds, catalogue,
│                   reports, SourceResult
├── services/       One class per API — DNS-over-HTTPS, crt.sh, RDAP,
│                   VirusTotal, AbuseIPDB, Shodan, OTX, HackerTarget,
│                   Wayback, bulk threat feeds, IANA/Mozilla registries
├── repositories/   Recon, threat intel, brand, namespace sweep, blocklists,
│                   due diligence, source catalogue
└── util/           Typosquat generation, CIDR matching, bounded concurrency,
                    lenient body decoding
```

Services take an injected `http.Client`, so every test runs against
`MockClient` with no network access.

## The SourceResult contract

Services never throw for an expected condition. They return one of:

- `SourceSuccess` — the source answered with usable data.
- `SourceEmpty` — the source answered and holds nothing. A real finding:
  "VirusTotal has never seen this hash" or an NXDOMAIN both land here.
- `SourceFailure` — the source could not be queried or refused. Carries
  `needsApiKey` so the UI can offer to open settings instead of showing an
  error.

Callers that fan out convert each result into a `SourceNote` and attach the set
to the report, so the distinction survives all the way to the screen.

## The source catalogue

`CatalogRepository` enumerates what the tool can consult by fetching the lists
the governing bodies publish — the IANA TLD list and RDAP bootstrap, Mozilla's
Public Suffix List, and the CT log list. Counts are therefore checkable against
their source rather than asserted, and they track reality as it changes.

It reports queryable sources and sweep namespaces separately. A public suffix
is somewhere a domain can exist, not a server that answers questions; adding
them together would inflate the headline and mislead.

A registry that cannot be fetched yields a zero-count section flagged `stale`
rather than aborting the load, and the UI marks those rows. A catalogue missing
one section beats no catalogue, provided the gap is visible.

## Adding a source

1. Add a service in `services/` taking an injected `http.Client`, returning
   `SourceResult`. Map every status code you expect onto the right variant —
   in particular, decide whether a 404 means empty or failure.
2. If it needs a credential, add it to `ApiKeySource` with its signup URL and
   read it through `ApiKeyProvider`.
3. Compose it into the relevant repository and add its `SourceNote` to the
   report.
4. Test it with `MockClient`: one test per status-code branch, plus a payload
   test covering the awkward parts of the real response shape.
