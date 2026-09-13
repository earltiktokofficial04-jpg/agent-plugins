// Manual, live smoke check of the keyless sources.
//
// Deliberately not part of the test suite: it reaches the real internet, so
// including it in CI would make the build depend on third-party uptime. Run it
// by hand when a source's response format is suspected to have changed:
//
//   dart run example/live_smoke.dart [domain]
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:osint_core/osint_core.dart';

Future<void> main(List<String> args) async {
  final domain = args.isNotEmpty ? args.first : 'example.com';

  // Respect any proxy the environment mandates, which corporate networks and
  // sandboxes both tend to.
  final inner = HttpClient()
    ..findProxy = HttpClient.findProxyFromEnvironment;
  final client = IOClient(inner);

  final dns = DnsOverHttpsService(client: client);
  // Consult the IANA bootstrap so the query goes to the TLD's own registry.
  final rdap = RdapService(
    client: client,
    bootstrapRegistry: IanaRegistryService(client: client),
  );
  final crtSh = CrtShService(client: client);

  stdout.writeln('== DNS ==');
  final records = await dns.resolveAll(domain, [
    DnsRecordType.a,
    DnsRecordType.ns,
    DnsRecordType.mx,
    DnsRecordType.txt,
  ]);
  if (records.isEmpty) {
    stdout.writeln('  (nothing resolved)');
  }
  for (final record in records.take(8)) {
    stdout.writeln('  $record');
  }

  stdout.writeln('== RDAP ==');
  switch (await rdap.domain(domain)) {
    case SourceSuccess(:final value):
      stdout.writeln('  answered by: ${value.registryServer}');
      stdout.writeln('  registrar:   ${value.registrar}');
      stdout.writeln('  registered:  ${value.registered}');
      stdout.writeln('  expires:     ${value.expires}');
      stdout.writeln('  nameservers: ${value.nameservers}');
      stdout.writeln('  dnssec:      ${value.dnssecSigned}');
      stdout.writeln('  statuses:    ${value.statuses}');
    case SourceEmpty(:final detail):
      stdout.writeln('  empty: $detail');
    case SourceFailure(:final message):
      stdout.writeln('  FAILED: $message');
  }

  stdout.writeln('== crt.sh ==');
  switch (await crtSh.certificates(domain)) {
    case SourceSuccess(:final value):
      final hosts = CrtShService.subdomainsFrom(domain, value);
      stdout.writeln('  ${value.length} certificates, ${hosts.length} hosts');
      for (final host in hosts.take(10)) {
        stdout.writeln('    $host');
      }
    case SourceEmpty(:final detail):
      stdout.writeln('  empty: $detail');
    case SourceFailure(:final message):
      stdout.writeln('  FAILED: $message');
  }

  client.close();
}
