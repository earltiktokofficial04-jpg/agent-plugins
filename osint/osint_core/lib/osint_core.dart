/// Passive OSINT engine for infrastructure recon, threat-intel enrichment,
/// brand protection and corporate due diligence.
///
/// Every source in this package is passive: data is read from public
/// resolvers, Certificate Transparency logs, registry RDAP endpoints and
/// third-party reputation databases. The package never sends traffic to the
/// target being investigated, and contains no active scanning, probing or
/// exploitation capability.
library;

export 'src/models/certificate.dart';
export 'src/models/dns_record.dart';
export 'src/models/ioc_verdict.dart';
export 'src/models/registration.dart';
export 'src/models/reports.dart';
export 'src/models/source_result.dart';
export 'src/models/target.dart';
export 'src/models/typosquat.dart';
export 'src/repositories/brand_repository.dart';
export 'src/repositories/due_diligence_repository.dart';
export 'src/repositories/recon_repository.dart';
export 'src/repositories/threat_intel_repository.dart';
export 'src/services/abuseipdb_service.dart';
export 'src/services/api_key_provider.dart';
export 'src/services/crtsh_service.dart';
export 'src/services/dns_over_https_service.dart';
export 'src/services/rdap_service.dart';
export 'src/services/shodan_service.dart';
export 'src/services/virustotal_service.dart';
export 'src/util/concurrency.dart';
export 'src/util/typosquat_generator.dart';
