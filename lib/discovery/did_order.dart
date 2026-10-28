/// DID scan ordering and the moving-vehicle safety blocklist, ported from
/// didscout's `discovery_did_order`/`MOVING_DISCOVERY_BLOCKED_NAME_PARTS`.
library;

/// VIN DIDs -- never read under any mode, by any discovery path.
const Set<String> vinDids = {'F190', 'F802'};

/// The ECU serial number DID -- never read by generic discovery (it isn't
/// a VIN, but carries the same privacy weight).
const String serialNumberDid = 'F18C';

/// A module's own profile `discover` ranges are scanned first; these are
/// the standardized ranges most likely to answer next.
const List<(int, int)> discoveryPriorityRanges = [
  (0xF180, 0xF1FF),
  (0x0100, 0x0FFF),
  (0x1000, 0x1FFF),
  (0x2000, 0x2FFF),
];

/// F4xx/F5xx and F8xx stay announcement-only via OBDonUDS; never offered
/// to the generic per-ECU discovery scan.
const List<(int, int)> discoveryExcludedRanges = [
  (0xF400, 0xF5FF),
  (0xF800, 0xF8FF),
];

const (int, int) discoveryFullRange = (0x0000, 0xFFFF);

/// The DID scan order for one ECU's discovery: [profileRanges] first, then
/// the standardized [discoveryPriorityRanges], then the rest of the DID
/// space ascending -- skipping [vinDids], [serialNumberDid], and
/// [discoveryExcludedRanges], and never visiting the same DID twice even
/// if it falls in more than one range.
List<int> discoveryDidOrder(List<(int, int)> profileRanges) {
  final ordered = <int>[];
  final seen = <int>{};

  void addRange(int start, int end) {
    for (var did = start; did <= end; did++) {
      if (!seen.add(did)) {
        continue;
      }
      final hex = did.toRadixString(16).toUpperCase().padLeft(4, '0');
      if (vinDids.contains(hex) || hex == serialNumberDid) {
        continue;
      }
      if (discoveryExcludedRanges.any(
        (range) => did >= range.$1 && did <= range.$2,
      )) {
        continue;
      }
      ordered.add(did);
    }
  }

  for (final range in profileRanges) {
    addRange(range.$1, range.$2);
  }
  for (final range in discoveryPriorityRanges) {
    addRange(range.$1, range.$2);
  }
  addRange(discoveryFullRange.$1, discoveryFullRange.$2);
  return ordered;
}

/// Substrings (case-insensitive) of an F197 system name that block
/// discovery on that ECU while the vehicle is moving, regardless of any
/// other opt-in -- steering/braking systems should never see discovery
/// traffic while the vehicle is in motion.
const List<String> movingDiscoveryBlockedNameParts = [
  'abs',
  'esc',
  'esp',
  'eps',
  'lenk',
  'steer',
  'airbag',
  'brems',
  'brake',
  'parksp',
];

/// True if [f197Name] (an ECU's identified system name, or null if
/// unknown) matches [movingDiscoveryBlockedNameParts].
bool movingDiscoveryBlocked(String? f197Name) {
  if (f197Name == null) {
    return false;
  }
  final lowered = f197Name.toLowerCase();
  return movingDiscoveryBlockedNameParts.any(lowered.contains);
}
