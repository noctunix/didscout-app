import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';

import 'package:didscout_app/bridge/didscout_policy.dart';

void main() {
  final policy = DidscoutPolicy();
  final filter = GuardedCommandFilter(policy);

  bool allowedThroughFilter(String command) =>
      filter.check(command) is GuardAllowed;

  group('adapter setup/identification', () {
    for (final command in [
      'ATZ',
      'ATE0',
      'ATL0',
      'ATS0',
      'ATH1',
      'ATI',
      'ATRV',
      'ATDP',
      'ATDPN',
      'STI',
      'STDI',
      'ATFCSD300000',
      'ATFCSM1',
      'ATCF700',
      'ATCM700',
    ]) {
      test('$command is allowed', () {
        expect(policy.allows(command), isTrue);
      });
    }

    test('an adapter command outside the allow-list is rejected', () {
      // Allowed by HardGuard, but not by this app's narrower policy.
      expect(policy.allows('ATMA'), isFalse);
      expect(policy.allows('ATCAF0'), isFalse);
      expect(policy.allows('ATD'), isFalse);
    });

    test(
      'a CAN filter/mask other than the discovery sweep value is rejected',
      () {
        expect(policy.allows('ATCF701'), isFalse);
        expect(policy.allows('ATCM000'), isFalse);
      },
    );
  });

  group('adapter response timeout (ATST)', () {
    test('ATST plus two hex digits is allowed', () {
      expect(policy.allows('ATST00'), isTrue);
      expect(policy.allows('ATST19'), isTrue);
      expect(policy.allows('ATSTFF'), isTrue);
    });

    test('a malformed ATST command is rejected', () {
      expect(policy.allows('ATST'), isFalse);
      expect(policy.allows('ATST1'), isFalse);
      expect(policy.allows('ATST123'), isFalse);
      expect(policy.allows('ATSTGG'), isFalse);
      expect(policy.allows('ATST1g'), isFalse);
    });
  });

  group('protocol selection', () {
    test('ATSP6 and ATSP7 are allowed', () {
      expect(policy.allows('ATSP6'), isTrue);
      expect(policy.allows('ATSP7'), isTrue);
    });

    test('every other protocol is rejected', () {
      expect(policy.allows('ATSP0'), isFalse);
      expect(policy.allows('ATSP5'), isFalse);
      expect(policy.allows('ATSP8'), isFalse);
      expect(policy.allows('ATSPA'), isFalse);
    });
  });

  group('11-bit headers', () {
    test('the physical range 0x700-0x7EF is allowed', () {
      expect(policy.allows('ATSH700'), isTrue);
      expect(policy.allows('ATCRA7EF'), isTrue);
      expect(policy.allows('ATFCSH77A'), isTrue);
    });

    test('the functional header 7DF is allowed', () {
      expect(policy.allows('ATSH7DF'), isTrue);
    });

    test('headers outside the allowed range are rejected', () {
      expect(policy.allows('ATSH6FF'), isFalse);
      expect(policy.allows('ATCRA7F0'), isFalse);
      expect(policy.allows('ATSH000'), isFalse);
    });
  });

  group('29-bit headers', () {
    test('18DAxxF1 physical request headers are allowed', () {
      expect(policy.allows('ATSH18DA04F1'), isTrue);
      expect(policy.allows('ATFCSH18DA10F1'), isTrue);
    });

    test('18DAF1xx physical response headers are allowed', () {
      expect(policy.allows('ATCRA18DAF104'), isTrue);
    });

    test('the functional header 18DB33F1 is allowed', () {
      expect(policy.allows('ATSH18DB33F1'), isTrue);
    });

    test('a header that is neither physical nor functional is rejected', () {
      // Neither the 18DAxxF1 request nor the 18DAF1xx response shape.
      expect(policy.allows('ATSH18DA1234'), isFalse);
      // Wrong priority byte (18DB, not 18DA) and not the functional header.
      expect(policy.allows('ATCRA18DB04F1'), isFalse);
    });
  });

  group('mode 01 and UDS 22 reads', () {
    test('a well-formed mode 01 read is allowed', () {
      expect(policy.allows('010C'), isTrue);
    });

    test('a malformed mode 01 read is rejected', () {
      expect(policy.allows('01'), isFalse);
      expect(policy.allows('010C00'), isFalse);
    });

    test('a well-formed UDS ReadDataByIdentifier is allowed', () {
      expect(policy.allows('22F40D'), isTrue);
    });

    test('any other service is rejected', () {
      expect(policy.allows('0304'), isFalse);
      expect(policy.allows('2E0100'), isFalse);
      expect(policy.allows('1401'), isFalse);
    });
  });

  group('combined with the hard guard', () {
    test('a VIN read passes this policy but is still blocked by HardGuard', () {
      expect(policy.allows('22F190'), isTrue);
      expect(allowedThroughFilter('22F190'), isFalse);
    });

    test('an ECU serial read is still blocked by HardGuard', () {
      expect(policy.allows('22F18C'), isTrue);
      expect(allowedThroughFilter('22F18C'), isFalse);
    });

    test('a plan command allowed by both layers passes through the filter', () {
      expect(allowedThroughFilter('22F40D'), isTrue);
      expect(allowedThroughFilter('ATSH18DA04F1'), isTrue);
    });
  });
}
