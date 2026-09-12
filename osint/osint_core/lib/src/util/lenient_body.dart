import 'dart:convert';

import 'package:http/http.dart' as http;

/// Decodes a response body without trusting its `Content-Type` header.
///
/// `http.Response.body` parses the header to pick a codec, and throws when the
/// header is malformed. Several of the volunteer-hosted threat feeds send
/// exactly that — GreenSnow returns `text/plain; charset: UTF-8;charset=UTF-8`,
/// with a colon where the parser wants an equals sign — which would otherwise
/// lose a whole feed over a punctuation error in someone's web server config.
///
/// The body is decoded as UTF-8 with malformed sequences replaced, falling
/// back to Latin-1 if that somehow fails. These feeds are ASCII address lists,
/// so no information is lost.
String decodeBodyLeniently(http.Response response) {
  try {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  } on FormatException {
    return latin1.decode(response.bodyBytes, allowInvalid: true);
  }
}
