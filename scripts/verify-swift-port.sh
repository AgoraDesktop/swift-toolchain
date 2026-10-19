#!/usr/bin/env bash
#
# Verify the Swift-on-Agora port end to end.
#
# Every check here corresponds to a claim in SWIFT-PORT-HANDOFF.md. It compiles
# and *runs* real programs, because `swiftc --version` and `-typecheck` alone
# never exercise the runtime the compiler and its output depend on.
#
#   swift-toolchain/scripts/verify-swift-port.sh
#
# Exits non-zero if any check fails. AGORA_PREFIX / AGORA_SWIFT_ROOT are read
# from native-env.sh, so the usual overrides apply.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

TOOLCHAIN="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
# The installed compiler is the default; VERIFY_SWIFTC lets the same gate run
# against a test compiler (e.g. the layout-2 one from build-layout2-stdlib.sh).
# NB: native-env.sh sets SWIFTC for the build scripts, so the override needs its
# own name.
SWIFTC="${VERIFY_SWIFTC:-$TOOLCHAIN/bin/swiftc}"
AGORA_LIBDIR="$AGORA_PREFIX/lib"
AGORA_INCDIR="$AGORA_PREFIX/include"
PROBE_MODULEMAP="$AGORA_ROOT/swift-interop-probe/agora-modules/module.modulemap"

# Programs find Agora's libraries through this; the Swift stdlib they also need
# is recorded as a DT_RUNPATH by the linker.  The inherited value is dropped on
# purpose: native-env.sh puts the *bootstrap* Swift runtime on it, and that
# runtime is not the one these programs were built against.
export LD_LIBRARY_PATH="$AGORA_LIBDIR"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

failures=0
check() {
  local name="$1"; shift
  if "$@" >"$WORKDIR/out" 2>&1; then
    printf '  [ok]   %s\n' "$name"
  else
    printf '  [FAIL] %s\n' "$name"
    sed 's/^/         /' "$WORKDIR/out" | head -20
    failures=$((failures + 1))
  fi
}

build_and_run() {
  local src="$1" bin="$2"
  shift 2
  "$SWIFTC" "$@" -L"$AGORA_LIBDIR" -o "$bin" "$src" || return 1
  "$bin"
}

# The stdlib an already-built program resolves at run time (installed or build
# tree, depending on how the gate was invoked).
linked_swiftcore() {
  ldd "$1" | awk '/libswiftCore\.so/ { print $3 }'
}

check_interop_exports() {
  local bin="$1" core
  core="$(linked_swiftcore "$bin")"
  [[ -n "$core" && -f "$core" ]] || {
    echo "cannot resolve libswiftCore for $bin"
    return 1
  }
  local symbol missing=0
  for symbol in objc_opt_self swift_getObjCClassMetadata \
                swift_getObjCClassFromMetadata; do
    # No `grep -q`: under `set -o pipefail` its early exit makes nm die of
    # SIGPIPE and turns a match into a failure.
    if ! nm -D --defined-only "$core" 2>/dev/null | grep -w "$symbol" >/dev/null; then
      echo "$symbol is not exported by $core"
      missing=1
    fi
  done
  (( missing == 0 ))
}

say() { printf '\n== %s\n' "$1"; }

if [[ ! -x "$SWIFTC" ]]; then
  echo "error: no swiftc at $SWIFTC (build the toolchain first)" >&2
  exit 1
fi

say "toolchain"
check "swiftc --version runs" "$SWIFTC" --version

say "the compiler parses, type-checks and compiles"
: > "$WORKDIR/empty.swift"
check "type-check an empty file" "$SWIFTC" -typecheck "$WORKDIR/empty.swift"

cat > "$WORKDIR/hello.swift" <<'EOF'
print("hello \(1 + 2)")
EOF
check "compile and run hello (compiler does not trap)" \
  build_and_run "$WORKDIR/hello.swift" "$WORKDIR/hello"

say "language and runtime"
# Classes (refcounting + vtables), inheritance + super, protocols and class
# existentials, generics, dictionaries, sets, closures, errors (at layout 2 the
# box is NSError-shaped: ErrorObject.mm), Unicode strings and optionals.
cat > "$WORKDIR/core.swift" <<'EOF'
protocol P { func name() -> String }
class A: P { var x = 1; func name() -> String { "A(\(x))" } }
class B: A { override func name() -> String { "B->" + super.name() } }
struct S: P { let v: Int; func name() -> String { "S(\(v))" } }
enum E: Error { case bad }

let items: [P] = [A(), B(), S(v: 7)]
precondition(items.map { $0.name() } == ["A(1)", "B->A(1)", "S(7)"])

var d = ["a": 1, "b": 2]; d["c"] = 3
precondition(d.sorted { $0.key < $1.key }.map(\.value) == [1, 2, 3])
precondition(Array(1...5).map { $0 * 2 }.reduce(0, +) == 30)
precondition(Set(["x", "y", "x"]).count == 2)
precondition([1, 2, 3].reduce(0) { $0 + $1 } == 6)

func f(_ x: Int) throws -> Int { if x < 0 { throw E.bad }; return x * 2 }
var caught = false
do { _ = try f(-1) } catch { caught = true }
precondition(caught && (try? f(3)) == 6)

let s = "héllo 🌍"
precondition(s.utf8.count == 11 && s.count == 7)
precondition((Optional(5).map { $0 + 1 } ?? 0) == 6)

print("core language features: ok")
EOF
check "run language/runtime program (-Onone)" \
  build_and_run "$WORKDIR/core.swift" "$WORKDIR/core-onone"
check "run language/runtime program (-O)" \
  build_and_run "$WORKDIR/core.swift" "$WORKDIR/core-opt" -O

say "Swift -> Agora (Objective-C interop)"
# Objective-C interop and the GNUstep runtime ABI are the default for this
# target (lib/Driver/ToolChains.cpp), so no -Xfrontend flags are needed: the
# only thing the user supplies is where Agora's headers and libraries are.
if [[ -f "$PROBE_MODULEMAP" ]]; then
  cat > "$WORKDIR/agora.swift" <<'EOF'
import Foundation

let o = NSObject.alloc()
precondition(o.isKind(of: NSObject.self))
// Swift's __allocating_init sugar: objc_allocWithZone -> +allocWithZone:.
let sugar = NSObject()
precondition(sugar.isKind(of: NSObject.self))
precondition(!o.isKind(of: NSString.self))
precondition((o.description() as String) == "NSObject")
let cls = object_getClass(o)!
precondition(String(cString: class_getName(cls)) == "NSObject")
print("agora interop: ok")
EOF
  check "allocate and message an Agora NSObject" \
    build_and_run "$WORKDIR/agora.swift" "$WORKDIR/agora" \
      -Xcc -fmodule-map-file="$PROBE_MODULEMAP" \
      -Xcc -I"$AGORA_INCDIR" \
      -Xcc -Wno-incomplete-umbrella \
      -lagora-base -lagora-core -lagora-dispatch -lobjc -lBlocksRuntime \
      -Xlinker -rpath -Xlinker "$AGORA_LIBDIR"

  # S6: the bootstrap shim (swift-toolchain/compat/ObjCInteropShim.c) is gone,
  # and it must stay unnecessary. The interop entry points a *program* calls
  # have to come from the libswiftCore the program actually links, not from an
  # object file every user has to remember to add. (The shim's fourth symbol,
  # swift_getObjCClassFromMetadataConditional, is internal to the runtime
  # upstream - it has no SWIFT_RUNTIME_EXPORT - and is only called from
  # MetadataLookup.cpp/ProtocolConformance.cpp, so a program never needs it.)
  check "interop entry points come from libswiftCore (no bootstrap shim)" \
    check_interop_exports "$WORKDIR/agora"
else
  echo "  [skip] swift-interop-probe/agora-modules/module.modulemap not present"
fi

say "Swift <-> Agora Foundation bridging"
# The value bridges live in the Foundation overlay the toolchain installs
# (swift-toolchain/foundation-overlay).  It is part of an *installed* toolchain;
# with VERIFY_SWIFTC pointing at a build tree the overlay is not there, so the
# check is skipped rather than failed.
if [[ -f "$PROBE_MODULEMAP" && "$SWIFTC" == "$TOOLCHAIN/bin/swiftc" ]]; then
  cat > "$WORKDIR/bridging.swift" <<'EOF'
import Foundation

let s: NSString = "héllo 🌍" as NSString
precondition(s.length == 8)
precondition((s as String) == "héllo 🌍")

let a = ["a", "b"] as NSArray
precondition(a.count == 2 && (a as? [String]) == ["a", "b"])

let d = ["k": 1] as NSDictionary
precondition((d as? [String: Int]) == ["k": 1])

let set = Set([1, 2, 3]) as NSSet
precondition((set as? Set<Int>) == [1, 2, 3])

let n = 42 as NSNumber
precondition((n as? Int) == 42)

struct Plain: Error { var code: Int }
do { throw Plain(code: 7) } catch let e as NSError {
  precondition(e.code == 1)
}

struct Custom: CustomNSError {
  static var errorDomain: String { return "ce" }
  var errorCode: Int { return 9 }
  var errorUserInfo: [String: Any] { return ["k": "v"] }
}
do { throw Custom() } catch let e as NSError {
  precondition((e.domain as String) == "ce" && e.code == 9)
  precondition(e.userInfo?["k"] != nil)  // userInfo imports as [AnyHashable: Any]?
}

// The defaults must not recurse (`errorCode` default goes through the stdlib's
// _getDefaultErrorCode, not the overridden Error._code witness).
struct DefaultCustom: CustomNSError {
  static var errorDomain: String { return "dc" }
}
do { throw DefaultCustom() } catch let e as NSError {
  precondition((e.domain as String) == "dc" && e.code == 1)
}
// Cocoa-shaped API surface the overlay adds on top of the Objective-C API.
let error = NSError(domain: "d", code: 4, userInfo: ["k": "v"])
precondition(error != nil && error!.code == 4)
precondition(error!.userInfo?["k"] != nil)

let array = ["x", "y"] as NSArray
var seen = ""
for element in array { seen += String(describing: element) }
precondition(seen == "xy")

let dict = ["a": 1, "b": 2] as NSDictionary
var total = 0
for (_, value) in dict { total += (value as? Int) ?? 0 }
precondition(total == 3)

let nsset = Set([1, 2, 3]) as NSSet
var setCount = 0
for _ in nsset { setCount += 1 }
precondition(setCount == 3)

precondition(NSString(string: "abc").length == 3)
precondition((NSObject() as AnyHashable) is AnyHashable)

print("bridging: ok")
EOF
  check "String/Array/Dictionary/Set/NSNumber and Error <-> NSError" \
    build_and_run "$WORKDIR/bridging.swift" "$WORKDIR/bridging" \
      -Xcc -fmodule-map-file="$PROBE_MODULEMAP" \
      -Xcc -I"$AGORA_INCDIR" \
      -Xcc -Wno-incomplete-umbrella \
      -lagora-base -lagora-core -lagora-dispatch -lobjc -lBlocksRuntime \
      -Xlinker -rpath -Xlinker "$AGORA_LIBDIR"
else
  echo "  [skip] bridging (the Foundation overlay ships with the installed toolchain)"
fi

say "imported signatures: swift_bridge"
# `NSString` and `NSArray` carry `__attribute__((swift_bridge(...)))` in Agora's
# headers (patch 0010), so the importer rewrites `NSString *` to `String` and
# `NSArray *` to `[Any]` - and SILGen puts an Objective-C object back on the
# wire at the boundary. The last two checks are the *fallback*: an
# unparameterized `NSDictionary *` stays the Objective-C class, because
# `[AnyHashable: Any]` has no `_ObjectiveCBridgeable` conformance here (that
# bridge is the `ObjectiveC` overlay's, which is not built). Before the
# importer learned to check, that shape asserted in IRGen instead.
if [[ -f "$PROBE_MODULEMAP" && "$SWIFTC" == "$TOOLCHAIN/bin/swiftc" ]]; then
  cat > "$WORKDIR/swiftbridge.swift" <<'EOF'
import Foundation

// NSString * -> String: parameter, result, property getter, and the reverse.
let mutable = NSMutableString()
mutable.append("abc")
let joined: String = mutable.appending("def")
precondition(String(describing: mutable) == "abc")
precondition(joined == "abcdef")
precondition(mutable.length == 3)

let error = NSError(domain: "dom", code: 7)!
let domain: String = error.domain
precondition(domain == "dom" && error.code == 7)

// NSArray * -> [Any]: `NSArray(array:)` takes a Swift array now.
let array = NSArray(array: ["x", "y", 3])
precondition(array.count == 3)
precondition((array as! [Any]).count == 3)

// String -> NSString * at an Objective-C entry point, and back.
let text: NSString = "hello" as NSString
precondition(text.length == 5 && (text as String) == "hello")

// NSDictionary * / NSSet * are bridged too (they need AnyHashable's bridge).
let exception = NSException(name: "n", reason: "r", userInfo: ["k": "v"])
precondition(exception != nil)
let readBack: [AnyHashable: Any]? = exception!.userInfo
precondition(readBack?["k"] != nil && readBack?.count == 1)
let name: String = exception!.name()
precondition(name == "n")
let nsset: Set<AnyHashable> = Set([1, 2] as NSArray as! [AnyHashable])
precondition(nsset.count == 2)

// Every fixed-width number and Float bridge to NSNumber.
precondition((Int8(3) as NSNumber) as? Int8 == 3)
precondition((UInt64.max as NSNumber) as? UInt64 == UInt64.max)
precondition((Float(1.5) as NSNumber) as? Float == 1.5)

// BOOL imports as Bool (the ObjectiveC module's ObjCBool path).
let number = NSNumber(integer: 1)
let truth: Bool = number.boolValue()
precondition(truth && NSNumber(bool: true).boolValue())

// The Foundation value types bridge to their Objective-C classes.
precondition(Data([1, 2, 3]) as NSData is NSData)
precondition((Data([1, 2, 3]) as NSData) as Data == Data([1, 2, 3]))
precondition(Date(timeIntervalSinceReferenceDate: 0) as NSDate is NSDate)
precondition((Date(timeIntervalSinceReferenceDate: 5) as NSDate) as Date
             == Date(timeIntervalSinceReferenceDate: 5))
precondition(URL(string: "https://example.com/a")! as NSURL is NSURL)
precondition(UUID(uuidString: "422658F6-E837-4B06-8557-916AA30918AF")!
             as NSUUID is NSUUID)
precondition(IndexPath(indexes: [1, 2]) as NSIndexPath is NSIndexPath)
precondition(TimeZone(identifier: "UTC") as NSTimeZone is NSTimeZone)
precondition(Locale(identifier: "en_US") as NSLocale is NSLocale)
precondition(DateComponents(year: 2020) as NSDateComponents is NSDateComponents)
precondition(PersonNameComponents() as NSPersonNameComponents is NSPersonNameComponents)
precondition(CharacterSet(charactersIn: "abc") as NSCharacterSet is NSCharacterSet)
precondition(IndexSet(integer: 1) as NSIndexSet is NSIndexSet)
precondition(Decimal("1.5") as NSDecimalNumber is NSDecimalNumber)
precondition(AffineTransform() as NSAffineTransform is NSAffineTransform)

// AnyHashable bridges to NSObject (what makes [AnyHashable: Any] legal).
let hashable: AnyHashable = AnyHashable(3)
precondition((hashable as NSObject) as? AnyHashable == hashable)

print("swift_bridge: ok")
EOF
  check "NSString -> String, NSArray/NSDictionary/NSSet, numbers, BOOL and the value types" \
    build_and_run "$WORKDIR/swiftbridge.swift" "$WORKDIR/swiftbridge" \
      -Xcc -fmodule-map-file="$PROBE_MODULEMAP" \
      -Xcc -I"$AGORA_INCDIR" \
      -Xcc -Wno-incomplete-umbrella \
      -lagora-base -lagora-core -lagora-dispatch -lobjc -lBlocksRuntime \
      -Xlinker -rpath -Xlinker "$AGORA_LIBDIR"
fi

say "zero-copy bridges"
# Darwin's collection and string bridges hand back *views* over the same storage
# (`__SwiftDeferredNSArray`, `__StringStorage`, ...) and adopt them back, rather
# than copying.  Ours now does too: the stdlib's deferred wrappers are registered
# GNUstep class objects at layout 2, and their Objective-C primitives use the
# `NSUInteger` encodings Clang sends (so typed dispatch reaches the Swift
# override instead of the inherited Foundation method).
if [[ -f "$PROBE_MODULEMAP" && "$SWIFTC" == "$TOOLCHAIN/bin/swiftc" ]]; then
  cat > "$WORKDIR/zerocopy.swift" <<'EOF'
import Foundation

func className(_ object: AnyObject) -> String {
  guard let name = object_getClassName(object) else { return "<no class>" }
  return String(cString: name)
}

// String -> NSString is a __StringStorage view over the same code units, and
// the derived NSString doors (which Agora implements over the primitives) work.
let text = "héllo 🌍"
let nsText = text as NSString
precondition(className(nsText) == "_TtCs15__StringStorage", className(nsText))
precondition(nsText.length == 8)
precondition((nsText.substring(from: 1) as String) == "éllo 🌍")
precondition(nsText.character(at: 0) == 0x68)
precondition(nsText.isEqual(to: "héllo 🌍"))
precondition(nsText.range(of: "🌍").location == 6)
precondition((nsText as String) == text)

// Array -> NSArray: non-verbatim elements are a __SwiftDeferredNSArray view.
let numbers = [10, 20, 30]
let nsNumbers = numbers as NSArray
precondition(className(nsNumbers) == "_TtCs22__SwiftDeferredNSArray",
             className(nsNumbers))
precondition(nsNumbers.count == 3)
precondition((nsNumbers.object(at: 1) as! Int) == 20)
precondition((nsNumbers.subarray(with: NSRange(location: 1, length: 2)) as! [Int])
             == [20, 30])
precondition((nsNumbers as? [Int]) == numbers)

// Verbatim elements: the contiguous storage itself, a registered class object.
let objects = [NSObject(), NSObject()] as NSArray
precondition(className(objects).hasPrefix("_TtGCs23_ContiguousArrayStorage"),
             className(objects))
precondition(objects.count == 2)

// Dictionary and Set views are registered class objects.  `allObjects` is
// Agora's `NSSet` method: it walks the primitives and starts with a
// `NSUInteger`-typed `-count`, which is what the typed-selector encoding fix
// makes reach the Swift override.
let dictionary = ["k": 1, "j": 2] as NSDictionary
precondition(className(dictionary).hasPrefix("_TtGC"), className(dictionary))
precondition(dictionary.count == 2)
precondition((dictionary.object(forKey: "k") as? Int) == 1)
precondition(dictionary.allKeys.count == 2)
precondition((dictionary as? [String: Int]) == ["k": 1, "j": 2])

let set = Set([1, 2, 3]) as NSSet
precondition(className(set).hasPrefix("_TtGC"), className(set))
precondition(set.count == 3)
precondition(set.allObjects.count == 3)
precondition((set as? Set<Int>) == [1, 2, 3])

print("zero-copy: ok")
EOF
  check "String/Array/Dictionary/Set bridge to views, and their primitives reach Swift" \
    build_and_run "$WORKDIR/zerocopy.swift" "$WORKDIR/zerocopy" \
      -Xcc -fmodule-map-file="$PROBE_MODULEMAP" \
      -Xcc -I"$AGORA_INCDIR" \
      -Xcc -Wno-incomplete-umbrella \
      -lagora-base -lagora-core -lagora-dispatch -lobjc -lBlocksRuntime \
      -Xlinker -rpath -Xlinker "$AGORA_LIBDIR"
fi

say "value types and header annotations"
# The long tails of the Cocoa value types (`Data`'s collection API, the set
# algebra on `IndexSet`/`CharacterSet`, `Decimal` arithmetic, `Calendar`'s date
# math and formatting) plus the four header annotations Darwin's Foundation
# uses: NS_TYPED_ENUM (NSNotificationName), NS_SWIFT_NAME, NS_REFINED_FOR_SWIFT
# and NS_SWIFT_SENDABLE.
if [[ -f "$PROBE_MODULEMAP" && "$SWIFTC" == "$TOOLCHAIN/bin/swiftc" ]]; then
  cat > "$WORKDIR/valuetypes.swift" <<'EOF'
import Foundation

func requiresSendable<T: Sendable>(_ value: T) {}

// Data is a RandomAccessCollection with the mutation surface Darwin's has.
var data = Data([1, 2, 3, 4])
precondition(data.count == 4 && data.startIndex == 0 && data.endIndex == 4)
precondition(data.first == 1 && data.last == 4)
precondition(data[1..<3] == Data([2, 3]))
precondition(data.map { $0 } == [1, 2, 3, 4])
data.append(5)
data.insert(0, at: 0)
precondition(data.remove(at: 0) == 0)
data.replaceSubrange(0..<2, with: [7, 8, 9])
precondition(Array(data.prefix(3)) == [7, 8, 9])
data.removeSubrange(0..<1)
precondition(data.subdata(in: 0..<2) == Data([8, 9]))
precondition(Data([1, 2, 3, 4]).range(of: Data([2, 3])) == 1..<3)
data.removeAll()
precondition(data.isEmpty)
let rawBytes: [UInt8] = [9, 8]
precondition(rawBytes.withUnsafeBytes { Data($0) } == Data([9, 8]))

// IndexSet is a SetAlgebra.
var indexes = IndexSet(integersIn: 0..<3)
indexes.insert(10)
precondition(indexes.contains(10) && indexes.count == 4)
precondition(indexes.union(IndexSet(integer: 20)).contains(20))
precondition(Set(indexes.intersection(IndexSet(integersIn: 1..<5))) == [1, 2])
precondition(Set(indexes.symmetricDifference(IndexSet(integersIn: 0..<2))) == [2, 10])
precondition(Set(indexes.subtracting(IndexSet(integersIn: 0..<2))) == [2, 10])
precondition(indexes.count(in: 0..<5) == 3)
precondition(indexes.contains(integersIn: 1..<3))
precondition(Set(indexes) == [0, 1, 2, 10])
precondition(Set(IndexSet([4, 5, 6])) == [4, 5, 6])
indexes.formIntersection(IndexSet(integersIn: 1..<3))
precondition(Set(indexes) == [1, 2])
indexes.remove(integersIn: 1..<2)
precondition(Set(indexes) == [2])

// CharacterSet is a SetAlgebra over Unicode.Scalar.
var chars = CharacterSet(charactersIn: "abc")
precondition(chars.contains("b"))
chars.insert("d")
precondition(chars.contains("d"))
precondition(chars.union(CharacterSet(charactersIn: "xyz")).contains("x"))
precondition(chars.intersection(CharacterSet(charactersIn: "bcd")).contains("c"))
precondition(!chars.intersection(CharacterSet(charactersIn: "bcd")).contains("a"))
chars.subtract(CharacterSet(charactersIn: "a"))
precondition(!chars.contains("a") && chars.contains("b"))
precondition(CharacterSet.decimalDigits.contains("7"))
precondition(CharacterSet.letters.contains("z"))
precondition(CharacterSet.alphanumerics.contains("7"))
precondition(CharacterSet.punctuationCharacters.contains("!"))
precondition(CharacterSet.urlPathAllowed.contains("/"))

// Decimal arithmetic, literals and comparisons.
var price: Decimal = 10
price += Decimal(2.5)
precondition(price == Decimal("12.5"))
precondition(Decimal(3) * Decimal(4) == Decimal(12))
precondition(Decimal(10) / Decimal(4) == Decimal("2.5"))
precondition(Decimal(10) - Decimal(4) == Decimal(6))
precondition(-Decimal(5) == Decimal(-5))
precondition(Decimal(0).isZero && !Decimal(1).isZero)
precondition(Decimal(3).magnitude == Decimal(3))
precondition((-Decimal(3)).sign == .minus)
precondition(Decimal.nan.isNaN && !Decimal(1).isNaN)

// Calendar date arithmetic and the formatter surface.
var calendar = Calendar(identifier: "gregorian")
calendar.timeZone = TimeZone(identifier: "UTC")
let epoch = Date(timeIntervalSinceReferenceDate: 0)
let nextDay = calendar.date(byAdding: .day, value: 1, to: epoch)!
precondition(nextDay.timeIntervalSinceReferenceDate == 86_400)
precondition(calendar.isDate(epoch, inSameDayAs: epoch))
precondition(calendar.startOfDay(for: epoch) == epoch)
precondition(calendar.component(.year, from: epoch) == 2001)
precondition(calendar.range(of: .day, in: .month, for: epoch) == 1..<32)
let interval = calendar.dateInterval(of: .day, for: epoch)
precondition(interval != nil && interval!.duration == 86_400)
precondition(calendar.dateComponents([.year, .month, .day], from: epoch).year == 2001)
precondition(calendar.dateComponents([.day], from: epoch, to: nextDay).day == 1)
let formatter = DateFormatter()
formatter.setDateFormat("yyyy")
formatter.setTimeZone(NSTimeZone(name: "UTC")!)
precondition(formatter.string(from: epoch as NSDate) == "2001")
precondition(!epoch.formatted().isEmpty)
precondition(epoch.ISO8601Format().contains("2001"))

// NS_TYPED_ENUM: NSNotificationName is a struct wrapper over String.
let notificationName: NSNotificationName = NSNotificationName(rawValue: "N")
let notification = NSNotification(name: notificationName, object: nil, userInfo: nil)
precondition(notification.name.rawValue == "N")
precondition(NSNotificationName._unconditionallyBridgeFromObjectiveC(
  notificationName._bridgeToObjectiveC() as? NSString) == notificationName)
precondition(Notification.Name(rawValue: "N") == notificationName)

// NS_REFINED_FOR_SWIFT: -getCharacters:range: is `__getCharacters` in Swift.
var units = [unichar](repeating: 0, count: 2)
("ab" as NSString).__getCharacters(&units, range: NSRange(location: 0, length: 2))
precondition(units == [97, 98])

// NS_SWIFT_NAME: -countOfIndexesInRange: is `count(in:)` in Swift.
precondition(IndexSet(integersIn: 0..<5).count(in: 0..<3) == 3)

// NS_SWIFT_SENDABLE: the two immutable classes cross concurrency domains.
requiresSendable(NSNull())
requiresSendable(NSUUID())

print("value types: ok")
EOF
  check "Data/IndexSet/CharacterSet/Decimal/Calendar surfaces and the header annotations" \
    build_and_run "$WORKDIR/valuetypes.swift" "$WORKDIR/valuetypes" \
      -Xcc -fmodule-map-file="$PROBE_MODULEMAP" \
      -Xcc -I"$AGORA_INCDIR" \
      -Xcc -Wno-incomplete-umbrella \
      -lagora-base -lagora-core -lagora-dispatch -lobjc -lBlocksRuntime \
      -Xlinker -rpath -Xlinker "$AGORA_LIBDIR"
fi

say "result"
if (( failures == 0 )); then
  echo "  all checks passed"
else
  echo "  $failures check(s) failed"
fi
exit $(( failures > 0 ))
