import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/discovery/did_order.dart';

void main() {
  group('discoveryDidOrder', () {
    test('profile ranges come first, in the order given', () {
      final order = discoveryDidOrder([(0x3000, 0x3002)]);
      expect(order.take(3), [0x3000, 0x3001, 0x3002]);
    });

    test('standardized priority ranges follow, before the full sweep', () {
      final order = discoveryDidOrder([]);
      expect(order.first, 0xF180);
      expect(order.indexOf(0xF180), lessThan(order.indexOf(0x0100)));
      expect(order.indexOf(0x0100), lessThan(order.indexOf(0x1000)));
      expect(order.indexOf(0x1000), lessThan(order.indexOf(0x2000)));
    });

    test('never visits the same DID twice even across overlapping ranges', () {
      final order = discoveryDidOrder([(0xF180, 0xF1FF)]);
      expect(order.toSet().length, order.length);
      // F190 (VIN) and F18C (serial) fall inside this range but are
      // excluded, so only 126 of its 128 DIDs are actually visited.
      expect(
        order.where((d) => d >= 0xF180 && d <= 0xF1FF).length,
        0xF1FF - 0xF180 + 1 - 2,
      );
    });

    test('excludes VIN DIDs and the serial number', () {
      final order = discoveryDidOrder([]);
      expect(order.contains(0xF190), isFalse);
      expect(order.contains(0xF802), isFalse);
      expect(order.contains(0xF18C), isFalse);
    });

    test('excludes the OBDonUDS-only announcement ranges', () {
      final order = discoveryDidOrder([]);
      expect(order.any((d) => d >= 0xF400 && d <= 0xF5FF), isFalse);
      expect(order.any((d) => d >= 0xF800 && d <= 0xF8FF), isFalse);
    });

    test('an excluded DID named in a profile range is still skipped', () {
      final order = discoveryDidOrder([(0xF400, 0xF410)]);
      expect(order.any((d) => d >= 0xF400 && d <= 0xF410), isFalse);
    });

    test('covers the full DID space exactly once, minus exclusions', () {
      final order = discoveryDidOrder([]);
      // F802 already falls inside the F800-F8FF exclusion range, so it
      // doesn't add to the count on top of it; F190 and F18C don't.
      final excludedCount =
          (0xF5FF - 0xF400 + 1) +
          (0xF8FF - 0xF800 + 1) +
          1 /* F190 */ +
          1 /* F18C */;
      expect(order.length, 0x10000 - excludedCount);
    });
  });

  group('priorityDidOrder', () {
    test('is a prefix of discoveryDidOrder, without the full-space tail', () {
      final profileRanges = [(0x3000, 0x3002)];
      final priority = priorityDidOrder(profileRanges);
      final full = discoveryDidOrder(profileRanges);
      expect(full.sublist(0, priority.length), priority);
      expect(priority.length, lessThan(full.length));
    });

    test('excludes VIN DIDs and the serial number, same as the full order', () {
      final priority = priorityDidOrder([]);
      expect(priority.contains(0xF190), isFalse);
      expect(priority.contains(0xF802), isFalse);
      expect(priority.contains(0xF18C), isFalse);
    });
  });

  group('movingDiscoveryBlocked', () {
    test('an unknown name is blocked', () {
      expect(movingDiscoveryBlocked(null), isTrue);
    });

    test(
      'a steering/braking/airbag system name is blocked, case-insensitively',
      () {
        for (final name in [
          'ABS',
          'esc module',
          'Lenkung',
          'Airbag Control',
          'Brake System',
        ]) {
          expect(movingDiscoveryBlocked(name), isTrue, reason: name);
        }
      },
    );

    test('an unrelated system name is not blocked', () {
      expect(movingDiscoveryBlocked('Gateway'), isFalse);
      expect(movingDiscoveryBlocked('Tyre Pressure Monitor'), isFalse);
    });
  });
}
