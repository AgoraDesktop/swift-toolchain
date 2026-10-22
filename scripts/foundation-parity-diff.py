#!/usr/bin/env python3
"""
foundation-parity-diff.py — compare two Foundation symbol graphs.

Reads the `swift-symbolgraph-extract` output for the reference Foundation (the
Linux build of swift-foundation, i.e. the API Darwin also ships) and for Agora's
Foundation (Agora's Objective-C classes plus the hand-written Swift overlay),
and reports what the reference has that we do not.

Modes
  --report              human-readable diff (default)
  --check               exit 1 on an unaccepted gap, a stale allowlist entry, or
                        a gap that grew past the count an entry records
  --write-allowlist P   write a fresh baseline allowlist to P and exit
  --update-allowlist P  rewrite the counts in P (reasons kept)

The comparison unit is `(dotted path, symbol kind)`, e.g.
`NSDateFormatter.dateStyle | swift.method`. A type that exists here but whose
member is a property rather than a method is therefore a gap in the *kind*
dimension, which is the point: Darwin's property-shaped surface is part of
parity.

Allowlist format (see parity/foundation-allowlist.txt):
  Foundation:<path prefix> count=<n> — <reason>
  Foundation:<Type> -> <Protocol> count=<n> — <reason>
A `count=` mismatch in either direction fails `--check`, so progress forces the
list to shrink.
"""

import argparse
import collections
import json
import os
import sys

# ---------------------------------------------------------------------------
# Loading


def load_graphs(directory):
    """Load one module's symbol graphs from a directory.

    Returns (symbols by precise id, relationships, main-graph symbols). The main
    graph is `<module>.symbols.json`; the `@…` files are re-export graphs, whose
    symbols belong to *other* modules (extensions of Swift types, DispatchData,
    …). They supply conformance edges and identifier resolution, but counting
    their symbols would measure those modules, not this one's surface.
    """
    symbols = {}
    relationships = []
    main = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".symbols.json"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as f:
            graph = json.load(f)
        is_main = "@" not in name
        for symbol in graph.get("symbols", []):
            symbols[symbol["identifier"]["precise"]] = symbol
            if is_main:
                main.append(symbol)
        for rel in graph.get("relationships", []):
            relationships.append(rel)
    return symbols, relationships, main


def load_modules(paths):
    """Merge several module directories: (symbols, relationships, main symbols).

    `import Foundation` on Darwin is one surface over three modules: Foundation
    itself (the Objective-C classes and their Swift shims), FoundationEssentials
    (the value types, coders, predicates, attributed strings) and
    FoundationInternationalization (locale, calendars, formatters). The
    reference must therefore be all three, or the largest part of the gap is
    invisible to the diff.
    """
    if isinstance(paths, str):
        paths = [paths]
    symbols, relationships, main = {}, [], []
    for path in paths:
        s, r, m = load_graphs(path)
        symbols.update(s)
        relationships.extend(r)
        main.extend(m)
    return symbols, relationships, main


def visible(symbol):
    """Symbols the surface promises: public/open, no underscored path segment."""
    if symbol.get("accessLevel") not in ("public", "open"):
        return False
    return not any(part.startswith("_") for part in symbol["pathComponents"])


def symbol_key(symbol):
    return ".".join(symbol["pathComponents"]), symbol["kind"]["identifier"]


def container(path):
    return path.split(".", 1)[0]


# ---------------------------------------------------------------------------
# Comparison


class Diff:
    def __init__(self, ref_dir, ours_dir):
        ref_symbols, ref_rels, ref_main = load_modules(ref_dir)
        our_symbols, our_rels, our_main = load_modules(ours_dir)
        self.ref = [s for s in ref_main if visible(s)]
        self.ours = [s for s in our_main if visible(s)]
        self.our_keys = {symbol_key(s) for s in self.ours}
        self.ref_keys = {symbol_key(s) for s in self.ref}

        # A missing path whose kind differs is reported as a shape gap: the
        # member exists but as the wrong Swift shape (method vs property).
        self.our_paths = collections.defaultdict(set)
        for path, kind in self.our_keys:
            self.our_paths[path].add(kind)

        self.missing = [s for s in self.ref if symbol_key(s) not in self.our_keys]
        self.missing_keys = {symbol_key(s) for s in self.missing}
        self.extra = [s for s in self.ours if symbol_key(s) not in self.ref_keys]
        self.ref_all_keys = {
            symbol_key(s) for s in ref_symbols.values() if visible(s)
        }
        self.ref_all_paths = {path for path, _ in self.ref_all_keys}
        self.our_paths_all = {path for path, _ in self.our_keys}

        self.conformance_gaps = self._conformance_gaps(
            ref_symbols, ref_rels, our_symbols, our_rels
        )

    # Conformances the compiler synthesizes rather than the declaration
    # stating them. The reference graph lists them; ours does not emit them at
    # this version, so counting them would report the compiler, not the surface.
    SYNTHESIZED_CONFORMANCES = {
        "Sendable", "SendableMetatype", "Copyable", "Escapable",
        "BitwiseCopyable",
    }

    @classmethod
    def _conformance_gaps(cls, ref_symbols, ref_rels, our_symbols, our_rels):
        """Conformances the reference declares and our surface does not.

        Edges come from every reference graph, because the value types are
        declared in FoundationEssentials' graph on the reference side; a source
        counts if the same path exists in our surface (whatever its module), and
        a protocol target may be outside the graph (`Swift.Codable`), in which
        case `targetFallback` names it.
        """

        def index(symbols):
            return {precise: s for precise, s in symbols.items() if visible(s)}

        def protocol_name(rel, index):
            target = index.get(rel["target"])
            if target is not None:
                return target["names"]["title"]
            fallback = rel.get("targetFallback", "")
            return fallback.rsplit(".", 1)[-1]

        ref_index, our_index = index(ref_symbols), index(our_symbols)
        our_conformances = collections.defaultdict(set)
        for rel in our_rels:
            if rel["kind"] != "conformsTo":
                continue
            source = our_index.get(rel["source"])
            if source is None:
                continue
            our_conformances[".".join(source["pathComponents"])].add(
                protocol_name(rel, our_index)
            )

        our_paths = {".".join(s["pathComponents"]) for s in our_index.values()}
        our_alias_paths = {
            ".".join(s["pathComponents"])
            for s in our_index.values()
            if s["kind"]["identifier"] == "swift.typealias"
        }
        gaps = []
        for rel in ref_rels:
            if rel["kind"] != "conformsTo":
                continue
            source = ref_index.get(rel["source"])
            if source is None:
                continue
            path = ".".join(source["pathComponents"])
            if path not in our_paths:
                continue  # reported as a missing type, not a conformance gap
            if source["kind"]["identifier"] == "swift.typealias" \
                    or path in our_alias_paths:
                # A typealias cannot declare conformances: on our side the
                # conformances belong to the aliased type (CGFloat is Double,
                # NSZone is a struct alias), so comparing them measures the
                # aliasing, not a missing declaration.
                continue
            protocol = protocol_name(rel, ref_index)
            if not protocol or protocol in cls.SYNTHESIZED_CONFORMANCES:
                continue
            if protocol not in our_conformances.get(path, set()):
                gaps.append((path, protocol))
        return sorted(set(gaps))

    # -- allowlist ---------------------------------------------------------

    @staticmethod
    def _strip_module(prefix):
        """`Foundation:NSData` -> `NSData`; the graph keys carry no module."""
        return prefix.split(":", 1)[1] if ":" in prefix else prefix

    def _match_symbol_entry(self, prefix):
        path = self._strip_module(prefix)
        return [k for k in self.missing_keys
                if k[0] == path or k[0].startswith(path + ".")]

    def _match_conformance_entry(self, type_path, protocol):
        path = self._strip_module(type_path)
        return [g for g in self.conformance_gaps
                if g[0] == path
                and (protocol == "*" or g[1] == protocol)]

    def check(self, entries):
        problems = []
        counted_symbols = collections.Counter()
        counted_conformances = collections.Counter()

        for entry in entries:
            if entry["kind"] == "symbol":
                matches = self._match_symbol_entry(entry["prefix"])
                counted_symbols[entry["prefix"]] += len(matches)
            else:
                matches = self._match_conformance_entry(
                    entry["prefix"], entry["protocol"]
                )
                counted_conformances[(entry["prefix"], entry["protocol"])] += len(
                    matches
                )
            actual, recorded = len(matches), entry["count"]
            if recorded == 0:
                problems.append(
                    f"empty entry: {entry['raw']} accepts nothing — delete it"
                )
            elif actual > recorded:
                problems.append(
                    f"gap grew: {entry['raw']} (allowlisted {recorded}, "
                    f"now {actual})"
                )
            elif actual < recorded:
                problems.append(
                    f"stale entry: {entry['raw']} (allowlisted {recorded}, "
                    f"now {actual}) — lower the count"
                )

        for key in sorted(self.missing_keys):
            if not any(
                e["kind"] == "symbol"
                and (key[0] == self._strip_module(e["prefix"])
                     or key[0].startswith(self._strip_module(e["prefix"]) + "."))
                for e in entries
            ):
                problems.append(f"unallowlisted gap: Foundation:{key[0]} ({key[1]})")
        for type_path, protocol in self.conformance_gaps:
            if not any(
                e["kind"] == "conformance"
                and self._strip_module(e["prefix"]) == type_path
                and e["protocol"] in (protocol, "*")
                for e in entries
            ):
                problems.append(
                    f"unallowlisted conformance gap: "
                    f"Foundation:{type_path} -> {protocol}"
                )
        return problems

    # -- baseline ----------------------------------------------------------

    def baseline_entries(self):
        """One entry per missing container, plus one per conformance gap."""
        counts = collections.Counter(
            container(path) for path, _ in self.missing_keys
        )
        present = {path.split(".", 1)[0] for path, _ in self.our_keys}
        entries = [
            {
                "kind": "symbol",
                "prefix": f"Foundation:{name}",
                "count": n,
                "reason": reason_for(name, name in present),
            }
            for name, n in sorted(counts.items())
        ]
        entries += [
            {
                "kind": "conformance",
                "prefix": f"Foundation:{type_path}",
                "protocol": "*",
                "count": n,
                "reason": reason_for(
                    container(type_path), container(type_path) in present
                ),
            }
            for type_path, n in sorted(
                collections.Counter(
                    type_path for type_path, _ in self.conformance_gaps
                ).items()
            )
        ]
        return entries

    # -- report ------------------------------------------------------------

    def report(self, entries, out=sys.stdout):
        by_container = collections.Counter(
            container(path) for path, _ in self.missing_keys
        )
        accepted = collections.Counter()
        for entry in entries:
            if entry["kind"] == "symbol":
                accepted[entry["prefix"].split(":", 1)[1]] += entry["count"]

        shape_gaps = [
            s for s in self.missing
            if self.our_paths.get(symbol_key(s)[0])
        ]

        print(f"reference symbols : {len(self.ref)}", file=out)
        print(f"our symbols       : {len(self.ours)}", file=out)
        print(
            f"missing           : {len(self.missing_keys)} distinct "
            f"({len(self.missing)} declarations, "
            f"{sum(1 for _ in by_container)} containers)",
            file=out,
        )
        print(
            f"  of which a member of the same path exists with another shape: "
            f"{len(shape_gaps)}",
            file=out,
        )
        print(f"extra (ours only) : {len(self.extra)}", file=out)
        print(f"conformance gaps  : {len(self.conformance_gaps)}", file=out)
        print(file=out)

        print("largest missing containers:", file=out)
        for name, n in by_container.most_common(25):
            reason = CLUSTER_REASONS.get(name, "")
            note = f"  — {reason}" if reason else ""
            print(f"  {n:5d}  {name}{note}", file=out)

        absent = [
            name for name in by_container
            if not any(path.split(".", 1)[0] == name for path, _ in self.our_keys)
        ]
        print(
            f"\ncontainers absent entirely: {len(absent)} "
            f"(of {len(by_container)} with gaps)",
            file=out,
        )

        TYPE_KINDS = {
            "swift.class", "swift.struct", "swift.enum", "swift.protocol",
            "swift.typealias", "swift.actor", "swift.enum.case",
        }
        extras = collections.Counter()
        for path, kind in {symbol_key(s) for s in self.extra}:
            if kind in TYPE_KINDS:
                extras[container(path)] += 1
        new_containers = sorted(
            name for name in extras
            if name not in {p.split(".", 1)[0] for p in self.ref_all_paths}
        )
        # CoreFoundation is a *separate module* on Darwin; Agora's Foundation
        # umbrella pulls CF's headers into the same Clang module, so its types
        # arrive here as extras. Reported apart from the Foundation-shaped ones,
        # which are the interesting signal.
        cf = [n for n in new_containers if n.startswith("CF")]
        other = [n for n in new_containers if not n.startswith("CF")]
        print(
            f"\nextra types not in the reference: {len(new_containers)} "
            f"containers ({len(cf)} CoreFoundation, {len(other)} Foundation-shaped)",
            file=out,
        )
        for name in other[:20]:
            print(f"  {name} ({extras[name]} type symbols)", file=out)
        if len(other) > 20:
            print(f"  … {len(other) - 20} more", file=out)

        if self.conformance_gaps:
            print("\nconformance gaps (type -> protocol):", file=out)
            for type_path, protocol in self.conformance_gaps:
                print(f"  {type_path} -> {protocol}", file=out)

        if entries:
            covered = sum(accepted.values())
            print(
                f"\nallowlist: {len(entries)} entries covering "
                f"{covered} of {len(self.missing_keys)} missing symbols",
                file=out,
            )


# ---------------------------------------------------------------------------
# Cluster reasons, used when generating a baseline allowlist. Kept short; the
# plan (SWIFT-FOUNDATION-PARITY-PLAN.md §5) owns the staging.

CLUSTER_REASONS = {
    # out of scope by the plan's §1
    "URLSession": "out of scope: FoundationNetworking",
    "NSURLSession": "out of scope: FoundationNetworking",
    # caps on T2: Agora's Objective-C Foundation has no such subsystem (§3.4)
    "Progress": "cap: no NSProgress in Agora's Foundation",
    "NSProgress": "cap: no NSProgress in Agora's Foundation",
    "ByteCountFormatter": "cap: no NSByteCountFormatter",
    "NSByteCountFormatter": "cap: no NSByteCountFormatter",
    "NSURLCredential": "cap: no URL loading subsystem",
    "URLCredential": "cap: no URL loading subsystem",
    # T3: FoundationEssentials / FoundationInternationalization (§3.3)
    "JSONEncoder": "T3: FoundationEssentials coders",
    "JSONDecoder": "T3: FoundationEssentials coders",
    "JSONSerialization": "T3: FoundationEssentials coders",
    "PropertyListEncoder": "T3: FoundationEssentials coders",
    "PropertyListDecoder": "T3: FoundationEssentials coders",
    "PropertyListSerialization": "T3: FoundationEssentials coders",
    "AttributedString": "T3: FoundationEssentials attributed strings",
    "AttributeContainer": "T3: FoundationEssentials attributed strings",
    "Predicate": "T3: FoundationEssentials predicates",
    "PredicateExpression": "T3: FoundationEssentials predicates",
    "Morphology": "T3: FoundationEssentials morphology",
    "Measurement": "T3: FoundationEssentials measurement",
    "Date": "T3/P1: FoundationEssentials date surface",
    "DateFormatter": "T3/P1: Internationalization formatters",
    "ISO8601DateFormatter": "T3/P1: Internationalization formatters",
    "NumberFormatter": "T3/P1: Internationalization formatters",
    "PersonNameComponentsFormatter": "T3/P1: Internationalization formatters",
    "DateIntervalFormatter": "T3/P1: Internationalization formatters",
    "Locale": "T3/P1: FoundationInternationalization",
    "NSLocale": "T3/P1: FoundationInternationalization",
    "TimeZone": "T3/P1: FoundationInternationalization",
    "Calendar": "T3/P1: FoundationInternationalization",
    "NSCalendar": "T3/P1: FoundationInternationalization",
    "URLComponents": "T3: FoundationEssentials URLComponents",
    "NSURLComponents": "cap + T3: no NSURLComponents in Agora",
    "URLQueryItem": "T3: FoundationEssentials URLComponents",
    "FormatStyle": "T3: FoundationEssentials format styles",
    # P1: names and annotations
    "Bundle": "P1: Bundle landed; the rest are member/property-shape gaps",
    "Process": "P1: rename layer (NSTask -> Process)",
    "FileHandle": "P1: renamed; member/property-shape gaps remain",
    "Pipe": "P1: renamed; member/property-shape gaps remain",
    "Port": "P1: renamed; member/property-shape gaps remain",
    "Stream": "P1: renamed; member/property-shape gaps remain",
    "Timer": "P1: renamed; member/property-shape gaps remain",
    "RunLoop": "P1: renamed; member/property-shape gaps remain",
    "Thread": "P1: renamed; member/property-shape gaps remain",
    "Operation": "P1: renamed; member/property-shape gaps remain",
    "OperationQueue": "P1: renamed; member/property-shape gaps remain",
    "Scanner": "P1: renamed; member/property-shape gaps remain",
    "UserDefaults": "P1: renamed; member/property-shape gaps remain",
    "NotificationQueue": "P1: renamed; member/property-shape gaps remain",
    "Host": "P1: renamed; member/property-shape gaps remain",
    # geometry lives in CoreGraphics, not Foundation
    "AlignmentOptions": "P1: imported OptionSet; the symbol graph omits its stored rawValue",
    "NSSortOptions": "P1: imported OptionSet; the symbol graph omits its stored rawValue",
    "NSEnumerationOptions": "P1: imported OptionSet; the symbol graph omits its stored rawValue",
    "NSBinarySearchingOptions": "P1: imported OptionSet; the symbol graph omits its stored rawValue",
    "CGFloat": "geometry: a typealias to Double here; a struct in the reference",
    "CGPoint": "geometry: CoreGraphics type, not re-exported",
    "CGSize": "geometry: CoreGraphics type, not re-exported",
    "CGRect": "geometry: CoreGraphics type, not re-exported",
    "AffineTransform": "P1: value-type long tail",
    "NSAffineTransform": "P1: value-type long tail",
    # predicates, measurement, progress: absent subsystems (§3.4) plus T3
    "NSComparisonPredicate": "cap: no NSPredicate; T3 Predicate arrives with FoundationEssentials",
    "NSCompoundPredicate": "cap: no NSPredicate; T3 Predicate arrives with FoundationEssentials",
    "NSPredicate": "cap: no NSPredicate; T3 Predicate arrives with FoundationEssentials",
    "NSExpression": "cap: no NSExpression; T3 Predicate arrives with FoundationEssentials",
    "InflectionRule": "T3: FoundationEssentials morphology",
    "NSMeasurement": "cap + T3: no NSMeasurement in Agora; arrives with FoundationEssentials",
    "Progress": "cap: no NSProgress in Agora's Foundation",
    "ProgressKind": "cap: no NSProgress in Agora's Foundation",
    "ProgressUserInfoKey": "cap: no NSProgress in Agora's Foundation",
    "ProgressReporting": "cap: no NSProgress in Agora's Foundation",
    # names that exist under another spelling here
    "AlignmentOptions": "P1: rename layer (NSAlignmentOptions -> AlignmentOptions)",
    "QualityOfService": "P1: rename layer (NSQualityOfService -> QualityOfService)",
    "Formatter": "P4: formatter base class",
    "NSLocale": "T3/P4: FoundationInternationalization",
    "NSZone": "P1: the importer maps NSZone to a Swift typealias; members differ",
    "ObjCBool": "P1: ObjectiveC overlay (already an alias); members differ",
    "NSRange": "P1: range helpers live in NSObjCRuntime.h as functions",
    "NSRangePointer": "P1: range helpers live in NSObjCRuntime.h as functions",
    "unichar": "P1: C typedef, imported as a typealias with no members",
    "TimeInterval": "P1: C typedef, imported as a typealias with no members",
    "NSObject": "P1: NSObject member long tail",
    "NSObjectProtocol": "P1: NSObjectProtocol member long tail",
    "ReferenceConvertible": "T3: the protocol arrives with FoundationEssentials",
    "CustomNSError": "P1: error-protocol long tail",
    "RecoverableError": "P1: error-protocol long tail",
    "NSCoding": "P1: archiving protocol suite",
    "NSSecureCoding": "P1: archiving protocol suite",
    "NSCopying": "P1: copying protocol suite",
    "NSMutableCopying": "P1: copying protocol suite",
    "NSDecimalNumberBehaviors": "P1: value-type long tail",
    "NSIndexSetIterator": "P1: value-type long tail",
    "BlockOperation": "P1: renamed; member/property-shape gaps remain",
    "===(_:_:)": "P1: operator re-export from the stdlib",
}


def reason_for(name, present):
    """The baseline reason for a container with missing symbols.

    Explicit names first, then the clusters that share one cause, so a generated
    allowlist explains itself instead of saying "unclassified".
    """
    if name in CLUSTER_REASONS:
        return CLUSTER_REASONS[name]
    if name.startswith(("AttributedString", "AttributedSubstring",
                        "DiscontiguousAttributedSubstring",
                        "MarkdownDecodableAttributedStringKey",
                        "AttributeScope", "AttributeContainer",
                        "AttributeDynamicLookup", "ScopedAttributeContainer")):
        return "T3: FoundationEssentials attributed strings"
    if name.startswith(("Predicate", "Expression", "StandardPredicateExpression")):
        return "T3: FoundationEssentials predicates"
    if name.startswith(("Sort", "KeyPathComparator", "ComparableComparator")) \
            or name in {"Comparator", "ComparisonResult"}:
        return "T3: FoundationEssentials sorting"
    if name.endswith(("ParseStrategy", "FormatStyleConfiguration", "StringStyle",
                      "NumberFormatConfiguration", "FormatStyleCapitalizationContext")):
        return "T3: FoundationEssentials format styles"
    if name.startswith(("Codable", "Encodable", "Decodable",
                        "EncodingConfiguration", "DecodingConfiguration")):
        return "T3: FoundationEssentials Codable configuration"
    if name in {"DataProtocol", "MutableDataProtocol", "ContiguousBytes"}:
        return "T3: FoundationEssentials data protocols"
    if name.startswith("File"):
        return "P1: rename layer (NSFileManager and its keys)"
    if name in {"NotificationCenter", "ProcessInfo", "OperatingSystemVersion",
                "StringLocalizationValue", "URLQueryItem", "NSCondition"}:
        return "P1: rename layer"
    if name.startswith("NSPersonNameComponent"):
        return "P1: NS_TYPED_ENUM members (Darwin imports them as enum cases)"
    if name.startswith("uuid"):
        return "P1: C typedef, imported as a typealias with no members"
    if name.startswith("Unit") or name == "Dimension" or name == "Measurement":
        return "T3: FoundationEssentials measurement"
    if name.endswith(("Formatter", "FormatStyle")):
        return "P4: Internationalization formatter"
    if name.startswith(("URL", "NSStringToDecimal")) or name in {
        "StringTransform", "NSURLQueryItem"
    }:
        return "T3: FoundationEssentials URL surface"
    if name.startswith((
        "Stream", "Socket", "Port", "Host", "NotificationQueue",
        "Operation", "FileHandle", "Pipe", "Bundle", "Scanner", "Timer",
        "RunLoop", "Thread", "UserDefaults", "NSFileManagerUnmount",
        "InputStream", "OutputStream",
    )):
        return "P1: rename layer"
    if name.startswith("NS" + "XPC"):
        return "out of scope: XPC (§1)"
    if name.endswith("Error") or name.endswith("ErrorKey"):
        return "P1: NS_ERROR_ENUM members (Darwin imports them as enum cases)"
    if "(_:" in name:
        if name.startswith(("NSMake", "NSMax", "NSMin", "NSMid", "NSWidth",
                            "NSHeight", "NSInset", "NSIntegral", "NSUnion",
                            "NSIntersection", "NSOffset", "NSDivide",
                            "NSPoint", "NSSize", "NSRect", "NSEqual",
                            "NSIsEmpty", "NSContains", "NSIntersects",
                            "NSStringFrom", "NSEdgeInsets")):
            return "P1: geometry helpers (NSGeometry.h)"
        return "re-export: Darwin's Foundation re-exports the C math library"
    if present:
        return "P1: type present, member long tail"
    return "absent from our surface — assign a stage"


# ---------------------------------------------------------------------------
# Allowlist parsing / writing


def parse_allowlist(path):
    entries = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            body, _, reason = line.partition("—")
            reason = reason.strip()
            tokens = body.split()
            if "->" in tokens:
                # Foundation:Type -> Protocol count=N
                i = tokens.index("->")
                prefix = " ".join(tokens[:i])
                protocol = tokens[i + 1]
                rest = tokens[i + 2:]
                kind = "conformance"
            else:
                prefix = tokens[0]
                protocol = None
                rest = tokens[1:]
                kind = "symbol"
            count = None
            for token in rest:
                if token.startswith("count="):
                    count = int(token.split("=", 1)[1])
            if count is None:
                raise SystemExit(f"allowlist: no count= in {raw!r}")
            entries.append(
                {
                    "kind": kind,
                    "prefix": prefix,
                    "protocol": protocol,
                    "count": count,
                    "reason": reason,
                    "raw": line,
                }
            )
    return entries


def write_allowlist(path, entries, header):
    lines = [header.rstrip("\n"), ""]
    for entry in entries:
        if entry["kind"] == "conformance":
            head = f"{entry['prefix']} -> {entry['protocol']}"
        else:
            head = entry["prefix"]
        reason = f" — {entry['reason']}" if entry.get("reason") else ""
        lines.append(f"{head} count={entry['count']}{reason}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


HEADER = """\
# Foundation parity allowlist — the accepted gaps between the reference
# Foundation (Linux swift-foundation) and Agora's Foundation.
#
# FORMAT
#   Foundation:<path prefix> count=<n> — <reason>
#   Foundation:<Type> -> <Protocol> count=<n> — <reason>
# A symbol entry covers that path and everything under it. `count` is the number
# of missing symbols (or missing conformance edges) the entry accepts as of the
# baseline. `verify-foundation-parity.sh --check` fails if a gap is
# unallowlisted, and *also* if a count is stale — so landings must shrink these
# numbers. Regenerate counts with
#   verify-foundation-parity.sh --update-allowlist
# and review the diff; add a `— reason` to every new entry.
#
# STAGES (SWIFT-FOUNDATION-PARITY-PLAN.md §5):
#   P1 — names, annotations, property shapes
#   P3 — FoundationEssentials bridge (value types, coders, predicates, …)
#   P4 — FoundationInternationalization (locale, calendars, formatters)
#   cap — Agora's Objective-C Foundation has no such subsystem (§3.4)
"""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", required=True, action="append",
                        help="reference module symbol-graph directory; repeat for "
                             "each module the reference Foundation re-exports")
    parser.add_argument("--ours", required=True, action="append",
                        help="Agora Foundation symbol-graph directory")
    parser.add_argument("--allowlist", default=None)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--report", action="store_true", default=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write-allowlist", metavar="PATH")
    mode.add_argument("--update-allowlist", metavar="PATH")
    args = parser.parse_args(argv)

    diff = Diff(args.reference, args.ours)

    if args.write_allowlist:
        entries = diff.baseline_entries()
        write_allowlist(args.write_allowlist, entries, HEADER)
        print(f"wrote {len(entries)} entries to {args.write_allowlist}")
        return 0

    entries = parse_allowlist(args.allowlist) if args.allowlist else []

    if args.update_allowlist:
        # Recompute every count, then *add* an entry for a gap nothing accepts:
        # a landing can close gaps (the count falls) and can also expose one
        # (renaming NSBundle to Bundle made Bundle's conformances measurable).
        # Both belong in the diff for review.
        for entry in entries:
            if entry["kind"] == "symbol":
                entry["count"] = len(diff._match_symbol_entry(entry["prefix"]))
            else:
                entry["count"] = len(
                    diff._match_conformance_entry(
                        entry["prefix"], entry["protocol"]
                    )
                )

        known = {(e["kind"], e["prefix"], e["protocol"]) for e in entries}
        uncovered = collections.Counter()
        for path, _kind in diff.missing_keys:
            name = container(path)
            if not any(
                e["kind"] == "symbol"
                and (path == diff._strip_module(e["prefix"])
                     or path.startswith(diff._strip_module(e["prefix"]) + "."))
                for e in entries
            ):
                uncovered[name] += 1
        for name, count in sorted(uncovered.items()):
            key = ("symbol", f"Foundation:{name}", None)
            if key not in known:
                entries.append(
                    {
                        "kind": "symbol",
                        "prefix": f"Foundation:{name}",
                        "protocol": None,
                        "count": count,
                        "reason": reason_for(name, name in diff.our_paths_all),
                    }
                )

        uncovered_conformances = collections.Counter()
        for type_path, protocol in diff.conformance_gaps:
            if not any(
                e["kind"] == "conformance"
                and diff._strip_module(e["prefix"]) == type_path
                and e["protocol"] in (protocol, "*")
                for e in entries
            ):
                uncovered_conformances[type_path] += 1
        for type_path, count in sorted(uncovered_conformances.items()):
            key = ("conformance", f"Foundation:{type_path}", "*")
            if key not in known:
                entries.append(
                    {
                        "kind": "conformance",
                        "prefix": f"Foundation:{type_path}",
                        "protocol": "*",
                        "count": count,
                        "reason": reason_for(
                            container(type_path),
                            container(type_path) in diff.our_paths_all,
                        ),
                    }
                )

        # A count of zero means the gap is closed; the entry has done its job.
        entries = [e for e in entries if e["count"] > 0]
        entries.sort(key=lambda e: (e["prefix"], e["kind"], e["protocol"] or ""))
        write_allowlist(args.update_allowlist, entries, HEADER)
        print(f"updated {len(entries)} entries in {args.update_allowlist}")
        return 0

    diff.report(entries)

    if args.check:
        if not args.allowlist:
            raise SystemExit("--check needs --allowlist")
        problems = diff.check(entries)
        print()
        if problems:
            for problem in problems[:50]:
                print(f"FAIL {problem}")
            if len(problems) > 50:
                print(f"… {len(problems) - 50} more")
            return 1
        print("parity gate: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
