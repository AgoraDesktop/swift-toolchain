# Building a Swift toolchain that targets Agora — natively

*Goal: a Swift compiler whose Objective-C platform is Agora, and whose only
GNUstep dependency is the runtime Agora already ships (`libagora-objc`,
libobjc2 v2.3). No GNUstep Foundation, no tools-make, no libs-corebase.*

No containers. Everything is installed under `$AGORA_SWIFT_ROOT` (default
`~/.agora-swift`) and Agora's `build-prefix` is consumed in place. Nothing
outside those two directories is touched, and nothing needs root.

Derived from `OpenSwiftProject/toolchain-docker`. Reasoning:
[`../SWIFT-TOOLCHAIN-INTEGRATION.md`](../SWIFT-TOOLCHAIN-INTEGRATION.md).

## Status — built and working (verified on this host)

The toolchain builds natively, compiles and runs Swift against Agora. Verified on
Debian 13 x86_64, 2026-10-17, by
[`scripts/verify-swift-port.sh`](scripts/verify-swift-port.sh):

```
$ swift-toolchain/scripts/verify-swift-port.sh
== toolchain
  [ok]   swiftc --version runs
== the compiler parses, type-checks and compiles
  [ok]   type-check an empty file
  [ok]   compile and run hello (compiler does not trap)
== language and runtime
  [ok]   run language/runtime program (-Onone)
  [ok]   run language/runtime program (-O)
== Swift -> Agora (Objective-C interop)
  [ok]   allocate and message an Agora NSObject
== result
  all checks passed
```

The installed toolchain is built with the **GNUstep class layout**
(`SWIFT_OBJC_CLASS_LAYOUT == 2`), so interop works in both directions: Swift can
import Agora's `Foundation`, allocate and message Agora objects, and read class
identity through libobjc2; and Agora sees Swift classes as real GNUstep class
objects (methods, ivars, categories, dispatch, `deinit`). See
[`../SWIFT-GNUSTEP-CLASS-ABI.md`](../SWIFT-GNUSTEP-CLASS-ABI.md) for the ABI and
the flip below.
[`../SWIFT-PORT-HANDOFF.md`](../SWIFT-PORT-HANDOFF.md) has the full state, the
change inventory, and the next steps.

### Layout 2 (the GNUstep class ABI) is the installed default

Since the 2026-10-17 flip, the installed `swiftc` and its stdlib are built with
`SWIFT_OBJC_CLASS_LAYOUT=2`: a Swift class with Objective-C ancestry is a real
GNUstep class object, generic and resilient classes included, and `deinit` runs
(S1-S5 of [`../SWIFT-GNUSTEP-CLASS-ABI.md`](../SWIFT-GNUSTEP-CLASS-ABI.md) are
all gated). The toolchain also ships a **Swift Foundation overlay**
(`foundation-overlay/`, installed as `lib/swift/linux/Foundation.swiftmodule` +
`libFoundation.so`) with the value bridges, `Error` <-> `NSError`, and the
Cocoa-shaped surface (`Sequence` collections, Swift-typed `NSError`/`NSString`
initializers, `NSObject: Hashable`); the gates run against the installed
toolchain like this:

```sh
swift-toolchain/scripts/verify-swift-port.sh          # language/runtime + interop
swift-interop-probe/scripts/run-native-probe.sh       # both probes, 17/17

T=~/.agora-swift/toolchain/usr
SKIP_BUILD=1 SWIFTC_LAYOUT2=$T/bin/swiftc \
  swift-toolchain/scripts/verify-class-abi.sh                       # S1/S3
SKIP_BUILD=1 SWIFTC_LAYOUT2=$T/bin/swiftc STDLIB_DIR=$T/lib/swift \
  swift-toolchain/scripts/verify-generic-abi.sh                     # S4
# ... verify-generic-objc-abi.sh (S4b/S4c), verify-refcount-abi.sh (S5) and
#     verify-update-abi.sh (library evolution): same env
```

The default in `Runtime/Config.h` and `native-env.sh` is 2. The compact layout is
still selectable, and going back is a rebuild:

```sh
AGORA_SWIFT_CLASS_LAYOUT=0 swift-toolchain/scripts/build-swift-toolchain.sh
# back to the default: swift-toolchain/scripts/build-swift-toolchain.sh
```

After the flip, the two build-tree helpers are no longer experiments:

* `build-layout2-frontend.sh` rebuilds only `swift-frontend` in the build tree
  and writes `bin/swiftc-layout2` (a wrapper with the same host-runtime
  environment as the installed `swiftc`). Handy to test a compiler change
  without reinstalling; the gates default to this wrapper.
* `build-layout2-stdlib.sh` builds `swift-frontend` *and* the stdlib in the
  build tree and writes `bin/swiftc-layout2-stdlib`. Use it when testing a
  compiler change that needs a matching runtime, since a compiler and stdlib
  from different layouts corrupt the heap for generic fields.

Library evolution's runtime-layout classes work too: a class with a
resiliently sized member (`verify-update-abi.sh`) uses `Update` when Swift
allocates it and `Singleton` when libobjc2 does - the class is registered after
its layout is final, so `objc_getClass` finds it only once its Swift metadata
has been requested.

A layout-2 build also covers code compiled with `-disable-objc-interop` (the
Dispatch overlay): such a compilation keeps the GNUstep *metadata shape* but
emits no class object identity, because there is no Objective-C runtime to
register it with. That path was fixed as part of the flip and is exercised by
`import Dispatch` in the shipped toolchain.

### The `ObjectiveC` module, and Cocoa-shaped signatures

The toolchain installs a small Swift module named `ObjectiveC`
(`objectivec-overlay/ObjectiveC.swift`) - the three types the Clang importer
looks up *by name*: `ObjCBool` (so every `BOOL` imports as `Bool`, and
`isEqual:`/`isKind(of:)`/`boolValue` are `Bool`), `Selector` (so `#selector`
works) and `NSZone`. The Foundation overlay re-exports it.

`CGFloat` is a `public typealias CGFloat = Double` in the overlay: the Clang
importer maps the C typedef to a Swift type of that name looked up in the
imported module, so without it `let w: CGFloat` is "cannot find type".

`libagora-objc` defines `BOOL` the way Apple does - `signed char` on x86_64,
`bool` on arm64 - so its type encoding (`c`, or `B` on arm64) agrees with the
one Swift emits for `Bool`. libobjc2 keys typed dispatch on (selector, encoding),
so a mismatch would make a clang-built `BOOL` send miss a Swift override; see
[`../SWIFT-PORT-HANDOFF.md`](../SWIFT-PORT-HANDOFF.md) §2.25.

### Imported signatures are Cocoa-shaped (`swift_bridge`)

`NSString` and `NSArray` carry `__attribute__((swift_bridge(...)))` in Agora's
headers (`patches/0010`), so `NSString *` imports as Swift `String` and
`NSArray *` as `[Any]`: `mutable.append("abc")`, `text.appending("def")` and
`NSArray(array: [1, 2, 3])` work, while Objective-C keeps the same selectors
and ABI. The bridge runs both ways at the boundary through the overlay's
`_ObjectiveCBridgeable` conformances.

It is a source change for Swift only: an `NSString` *variable* at such a
boundary needs `as String`, and an `NSArray` variable needs `as! [Any]`
(Objective-C is untouched - same selectors, same ABI).

The importer only performs that rewrite when the Swift type can be bridged
*back* to an Objective-C object (`canBridgeBackToObjectiveC()` in
`lib/ClangImporter/ImportType.cpp`), so an attribute on a type with no bridge
falls back to the Objective-C class instead of aborting IRGen.
`NSDictionary *`/`NSSet *` bridge to `[AnyHashable: Any]`/`Set<AnyHashable>`
because the overlay now supplies `AnyHashable: _ObjectiveCBridgeable`, and every
fixed-width number plus `Float` bridges to `NSNumber`. `verify-swift-port.sh`
covers all of it, including the Foundation value types.

**S4b — generic classes with an Objective-C ancestor.** A generic class cannot
have `@objc` members but can inherit `NSObject`, and then Swift allocates it
through `objc_allocWithZone`, so it has to be a registered class object:

```sh
swift-toolchain/scripts/verify-generic-objc-abi.sh
```

Covers the metaclass in the metadata pattern, the per-instantiation Objective-C
name, the initializer method list and `objc_loadClass_np()` registration, from
Swift and from C. The same gate also builds a `-enable-library-evolution` module
and checks the **resilient** case (S4c): a client subclass of an ObjC-rooted
class is relocated at runtime, registered, and gets correct field offsets,
including through a resilient superclass chain. `deinit` for these classes is
part of S5 and now runs.

**S5 — typed selector records.** libobjc2 keys type-dependent dispatch by
(name, encoding), and a class's dispatch table starts as its superclass's, so a
Swift method whose selector record was untyped was invisible to Clang-compiled
typed sends - including libobjc2's own release path, which sends
`dealloc_v16@0:8`:

```sh
swift-toolchain/scripts/verify-refcount-abi.sh
```

Checks `deinit` for fixed, generic and resilient ObjC-ancestry classes, typed
`-init`/`-dealloc`/method dispatch from Clang-compiled Objective-C,
retain/release balance, and 50k alloc/init/release cycles for leaks. The
compiler emits one selector record per (name, encoding) with Clang's symbol
mangling, so records from the two emitters merge.

**Imported Objective-C superclasses are part of the static layout.** Darwin's
runtime slides a Swift class's `instance_size` and ivar offsets when it realizes
the class, so IRGen lays the fields out from the isa word there; libobjc2 does
not slide anything. A Swift class whose superclass comes from Objective-C
therefore adds that class's `getASTObjCInterfaceLayout()` size as padding before
its own fields (gated on `usesGNUstepClassABI()`, the same computation clang's
`CGObjCGNU` backend makes). A subclass of `NSView` is 504 bytes with its first
field at 496 instead of 16 bytes with the field at 8. A superclass whose ivars
exist only in its `@implementation` (invisible to a module importer) is emitted
late-bound instead: `instance_size` 0, which libobjc2's
`objc_compute_ivar_offsets()` computes from the runtime superclass, with the
result mirrored into Swift's own `InstanceSize` word by a weak
`swift_objcClassLayoutDidChange()` hook — see
[`../SWIFT-GNUSTEP-CLASS-ABI.md`](../SWIFT-GNUSTEP-CLASS-ABI.md) §3 and
[`../swift-interop-probe/conformance/FINDINGS.md`](../swift-interop-probe/conformance/FINDINGS.md).

**The class object also publishes its `@objc` protocol conformances.** The
GNUstep `protocols` field was null, so `class_conformsToProtocol:` answered `NO`
for a Swift delegate. The list is GNUstep's `struct objc_protocol_list`
(`{ next, count, list[] }`), and an imported protocol's entry is clang's
`._OBJC_PROTOCOL_<name>` record from the defining image — the object libobjc2
registered, and the one a pointer-compare conformance check needs. A protocol
declared in Swift is emitted in the same GNUstep shape, in `__objc_protocols`,
so the runtime registers that one too. See
[`../SWIFT-PORT-HANDOFF.md`](../SWIFT-PORT-HANDOFF.md) §2.24 and §2.27.

`SWIFT_OBJC_CLASS_LAYOUT` is a CMake cache option (`CMakeLists.txt`; empty = the
platform default from `Runtime/Config.h`, which is 2), and
`AGORA_SWIFT_CLASS_LAYOUT` (default 2) passes it through
`build-swift-toolchain.sh`. A plain `swift-toolchain/scripts/build-swift-toolchain.sh`
is now the layout-2 install. S6 (dead shims and redundant flags) is done too: see
[`../SWIFT-PORT-HANDOFF.md`](../SWIFT-PORT-HANDOFF.md) §2.13.

### Three things about the installed compiler

1. **`swiftc` is a wrapper, and the host runtime ships with the toolchain.**
   The compiler is a host tool: it was built by the bootstrap toolchain against
   *that* toolchain's non-interop standard library, while the stdlib installed
   here is the interop one that compiled programs use. `_runtime(_ObjC)` changes
   `Array`'s storage type, so the two standard libraries are not ABI-compatible,
   and the compiler must run on the one it was built with. The install copies
   those six libraries into `lib/swift/host/runtime/` and `build-swift-toolchain.sh`
   writes a `swiftc` script that puts `$bindir/../lib/swift/host/runtime` first
   on `LD_LIBRARY_PATH` and then `exec -a swiftc`s `swift-frontend`. Override
   with `AGORA_SWIFT_HOST_RUNTIME`. Produced programs are unaffected: they get
   the toolchain stdlib through the `DT_RUNPATH` the linker records. The
   bootstrap tree is therefore build-time only - the installed toolchain works
   without it (handoff §2.15).

   (Do not re-create `swiftc` as a symlink to `swift-frontend`: the wrapper
   itself must not be written through a symlink, and an earlier version of the
   build script did exactly that and overwrote the 436 MB compiler binary with a
   five-line script. The script now `rm -f`s it first.)

2. **Interop is the default for this target.** The driver enables
   `-enable-objc-interop` for Linux and the frontend defaults the runtime ABI
   family to GNUstep, so a program that imports Agora needs only where the
   headers and libraries are:

   ```sh
   swiftc -o prog prog.swift \
     -Xcc -fmodule-map-file=agora-modules/module.modulemap \
     -Xcc -I<prefix>/include -Xcc -Wno-incomplete-umbrella \
     -L<prefix>/lib -lagora-base -lagora-core \
     -Xlinker -rpath -Xlinker <prefix>/lib
   ```

   `-Xfrontend -disable-objc-interop` still turns it off. This is not just a
   convenience: the installed stdlib is the interop one, and `_runtime(_ObjC)`
   changes its ABI (`Array`'s storage type), so compiling without interop means
   compiling against a different standard library than the one that is linked.
   One inner build opts out and must: libdispatch's `Dispatch` overlay is not
   interop-aware, so `patches/0004-libdispatch-overlay-non-interop.patch` keeps
   it on the non-interop ABI.

3. **`super.` sends use libobjc2's lookup.** libobjc2 exports no
   `objc_msgSendSuper2`; IRGen now emits `objc_msg_lookup_super` followed by a
   direct IMP call for Swift super sends into imported classes, so such programs
   link. Verified end to end by `objc-to-swift-probe` with the installed
   layout-2 compiler (`super -init` is reached).

### The probes

[`../swift-interop-probe/scripts/run-native-probe.sh`](../swift-interop-probe/scripts/run-native-probe.sh)
builds and runs both probes against this toolchain without SwiftPM.
`agora-import-probe` passes every check, and so does `objc-to-swift-probe` with
the installed toolchain (both directions of interop; the only item left is the
known `[gap]`: no `ObjectiveC` overlay, so `#selector` is unavailable).

Bootstrap Swift 6.3.3 (the Ubuntu 24.04 tarball) runs on Debian 13 with no
missing shared libraries. A full build takes ~1.5 h; an incremental build after
a runtime-only change is 1–3 min, and after an ABI-header or IRGen change
~15 min. The source build tree reaches 13 GB.

### Three findings from the first real run

1. **A C compiler is needed for linking.** The toolchain uses the legacy
driver, which shells out to `clang` and looks for it next to the frontend.
`build-swift-toolchain.sh` copies the bootstrap's static `clang` into the
toolchain's `bin/` (with its `lib/clang/21` resource directory), so `swiftc`
works out of the box and does not point back into the bootstrap tree.
2. **The Swift runtime's interop entry points were not exported.** `objc_opt_self`,
`swift_getObjCClassMetadata` and `swift_getObjCClassFromMetadata{,Conditional}`
used to be missing from the built `libswiftCore.so`
(OpenSwiftProject/swift#2), so any program touching an imported Objective-C
class failed to link. The fork now exports them all
(`GNUstepObjCCompatibility.mm` and the `#if SWIFT_OBJC_INTEROP` block in
`Metadata.cpp`), so the bootstrap shim is gone: `swift-toolchain/compat/` was
deleted in S6, and `verify-swift-port.sh` now asserts that the entry points are
exported by the `libswiftCore` a program actually links.
3. **`NSObject()` used to fail; it works now.** Swift's allocating-init sugar
allocates through `objc_allocWithZone`, which sends `+allocWithZone:` — which
Agora had removed under its no-zone-API policy, so the call raised
`-[NSObject allocWithZone:] is not implemented`. `NSObject` now implements a
compatibility door that ignores its argument and forwards to `+alloc`
(`patches/0005-libagora-base-allocWithZone.patch`): `NSObject()`, `NSNull()` and
`NSMutableArray()` all work, and a subclass's `+alloc` override still wins, so
singletons stay singletons. It does **not** make a Swift subclass of `NSObject`
allocatable: libobjc2 inspects `cls->isa` before sending any message, and compact
Swift metadata is not a class object (S1).

## 1. The header prerequisites (patches/)

The Swift stdlib's Objective-C interop compiles five `.mm` sources, chiefly
`SwiftObject.mm`, which `#import <Foundation/Foundation.h>`. Those are
Objective-C++, and Agora's headers were not Objective-C++-clean. Three headers
need adjusting; all changes are API-preserving (parameter names are not part of
a selector).

| Patch | Header | Change |
|---|---|---|
| `0001-libagora-base-objcxx-clean.patch` | `NSDateFormatter.h` | parameter `template` → `aTemplate` (×2) |
| | `NSRegularExpression.h` | parameter `template` → `aTemplate` (×2) |
| `0002-libagora-core-objcxx-clean.patch` | `include/ForSwiftFoundationOnly.h` | `struct stat` designated initializer: declaration order + `(off_t)`/`(blkcnt_t)` casts |

`template` is a C++ keyword; the rename keeps the selector
(`dateFormatFromTemplate:options:locale:`) unchanged. The `statx` initializer is
C99 and narrows `__u64`→`off_t`, an error in C++.

The other two patches are not header fixes, but they are applied the same way:
`0003-swift-enable-objc-interop.patch` is the whole Swift fork change set
(interop by default, the GNUstep runtime family, the class-object predicate -
including "a runtime-instantiated pattern class without ObjC ancestry is not a
class object", and "an `@_swift_native_objc_runtime_base` storage class is
one" - and the `NSUInteger` encodings of the collection cores), and
`0004-libdispatch-overlay-non-interop.patch` keeps libdispatch's `Dispatch`
overlay on the non-interop ABI it has always had (its shims are not
interop-aware), and `0005-libagora-base-allocWithZone.patch` adds the
`+allocWithZone:` compatibility door to `NSObject`. Regenerate `0003` with
`git -C ~/.agora-swift/src/swift diff HEAD > swift-toolchain/patches/0003-swift-enable-objc-interop.patch`
(`HEAD` also picks up the intent-to-add `TargetConditionals.h`).

**Already applied** to the working trees. To re-apply on a clean tree:

```sh
git -C libagora-base apply swift-toolchain/patches/0001-libagora-base-objcxx-clean.patch
git -C libagora-core apply swift-toolchain/patches/0002-libagora-core-objcxx-clean.patch

# the Swift fork itself
git -C ~/.agora-swift/src/swift apply swift-toolchain/patches/0003-swift-enable-objc-interop.patch

# libdispatch's Dispatch overlay: keep it non-interop
git -C ~/.agora-swift/src/swift-corelibs-libdispatch \
  apply swift-toolchain/patches/0004-libdispatch-overlay-non-interop.patch

# NSObject +allocWithZone: compatibility door (rebuild/reinstall libagora-base)
git -C libagora-base apply swift-toolchain/patches/0005-libagora-base-allocWithZone.patch

# libobjc2: objc_loadClass_np(), the dtable rebuild, and the autorelease-pool
# init (rebuild/reinstall libobjc, or copy build/libobjc.so.4 into the prefix)
git -C libagora-objc apply swift-toolchain/patches/0006-libagora-objc-loadClass-np.patch
git -C libagora-objc apply swift-toolchain/patches/0008-libagora-objc-dtable-rebase-untyped.patch
git -C libagora-objc apply swift-toolchain/patches/0011-libagora-objc-autorelease-pool-init.patch

# Agora's NSString: the stdlib's tagged-string probe and -isNSString__
git -C libagora-base apply swift-toolchain/patches/0007-libagora-base-tagged-string-probe.patch

# properties, swift_bridge attributes, the Swift header annotations
# (rebuild/reinstall libagora-base)
git -C libagora-base apply swift-toolchain/patches/0009-libagora-base-property-shaped-accessors.patch
git -C libagora-base apply swift-toolchain/patches/0010-libagora-base-swift-bridge-attributes.patch
git -C libagora-base apply swift-toolchain/patches/0012-libagora-base-swift-annotations.patch

# NSCalendar keeps the time zone it is given (rebuild/reinstall libagora-base)
git -C libagora-base apply swift-toolchain/patches/0013-libagora-base-nscalendar-retain-timezone.patch
```

Verified with clang 19 (`-std=c++17 -fobjc-runtime=gnustep-2.0`): the full
`Foundation/Foundation.h` umbrella compiles as Objective-C++ with zero errors
and zero warnings once these three are fixed (before: six diagnostics). After
editing, rebuild/reinstall so `build-prefix/include` sees the changed headers.

## 2. Layout

Everything lives under `$AGORA_SWIFT_ROOT`:

```
~/.agora-swift/
├── downloads/            # swift.org tarball
├── bootstrap/usr/        # official Swift 6.3.3 (bootstrap only; build tool)
├── bin/ninja             # fetched, no root
├── src/                  # swift-projects: swift fork, llvm-project, libdispatch, …
├── build/                # cmake/ninja build trees
├── runtime/              # this build's Swift-capable libdispatch
└── toolchain/usr/        # the result: swiftc, its host runtime and clang,
                          # and the stdlib targeting Agora - self-contained;
                          # only the build needs bootstrap/
```

Agora's `build-prefix` (header + libraries) is read from the release repository;
it is not copied anywhere.

## 3. Build

```sh
swift-toolchain/scripts/build-native.sh
```

That runs, in order:

| Script | What it does |
|---|---|
| `install-bootstrap-swift.sh` | fetches swift.org Swift 6.3.3 into `bootstrap/` (build tool only) |
| `install-ninja.sh` | fetches a `ninja` binary into `bin/` (no root, no apt) |
| `clone-sources.sh` | clones the Swift fork (`feature/gnu_objc_6.3`), LLVM `swift/release/6.3`, swift-corelibs-libdispatch — **no GNUstep repos** |
| `build-agora-baseline.sh` | builds the Swift-capable `swift-corelibs-libdispatch`; libobjc2 is Agora's, no GNUstep libs |
| `build-swift-toolchain.sh` | builds LLVM + Swift + stdlib with `SWIFT_STDLIB_ENABLE_OBJC_INTEROP=TRUE`, pointing `CPATH`/`LIBRARY_PATH` at Agora; installs the host runtime, clang and the Foundation overlay (`build-foundation-overlay.sh`) and self-checks the result |

Useful controls: `AGORA_SWIFT_ROOT=…`, `AGORA_PREFIX=…`,
`AGORA_TARGET_TRIPLE=linux-aarch64`, `BUILD_JOBS=…`,
`AGORA_SKIP=clone,baseline`, `AGORA_INSTALL_DEPS=1`.

### The missing dev headers

Two optional development headers are not installed. `build-native.sh` warns and
prints the fix:

```sh
sudo apt-get install -y libcurl4-openssl-dev libedit-dev
```

`libcurl` is needed by swift-corelibs-foundation; `libedit` by the Swift
driver/REPL. Set `AGORA_INSTALL_DEPS=1` to have the script run that for you.

## 4. What makes it "target Agora"

One change in `build-swift-toolchain.sh`, everything else being upstream's flags:

```sh
export CPATH="$AGORA_PREFIX/include:$OPEN_SWIFT_RUNTIME_PREFIX/include..."
export LIBRARY_PATH="$AGORA_PREFIX/lib:$OPEN_SWIFT_RUNTIME_PREFIX/lib..."
```

That is what makes the stdlib's `#import <Foundation/Foundation.h>` resolve to
Agora. The Objective-C runtime is Agora's libobjc2; the fork's
`-objc-runtime-vendor=gnustep` only selects libobjc2's ABI v2, which Agora
already emits via `-fobjc-runtime=gnustep-2.0`.

The bootstrap Swift is never linked against Agora — Agora's libraries are
deliberately kept off the bootstrap's `LD_LIBRARY_PATH`. They are added only for
the stdlib being compiled and, at run time, for the programs that use it.

## 5. Build a program against Agora

SwiftPM is not built (it is not part of this step), so compile directly. No
bootstrap shim is involved: the fork's runtime exports `objc_opt_self`,
`swift_getObjCClassMetadata` and `swift_getObjCClassFromMetadata` itself (S6
deleted the old `compat/` shim, and the language gate checks the exports).

```sh
T=~/.agora-swift/toolchain/usr
A=/path/to/Agora

"$T/bin/swiftc" -o /tmp/prog prog.swift \
  -Xcc -fmodule-map-file="$A/swift-interop-probe/agora-modules/module.modulemap" \
  -Xcc -I"$A/build-prefix/include" \
  -Xcc -Wno-incomplete-umbrella \
  -L"$A/build-prefix/lib" -lagora-base -lagora-core -lagora-dispatch -lobjc -lBlocksRuntime \
  -Xlinker -rpath -Xlinker "$A/build-prefix/lib"

LD_LIBRARY_PATH="$A/build-prefix/lib" /tmp/prog
```

The stdlib is found through the `DT_RUNPATH` the linker bakes in; only Agora's
libraries need `LD_LIBRARY_PATH` (and the link-time `-L`). `AGORA_PREFIX`
makes the driver add Agora's `-L`/`-l` flags automatically
(`lib/Driver/UnixToolChains.cpp`), in which case only the `-Xcc` flags and the
`rpath` are needed above. Interop and the GNUstep runtime family are defaults for
this target, so no `-Xfrontend` flags are needed.

Both `NSObject.alloc()` and `NSObject()` work: the latter goes through
libobjc2's `objc_allocWithZone` and the `+allocWithZone:` compatibility door
(finding 3 above), which forwards to `+alloc` so subclass overrides and
singletons are unaffected.

## 6. What to check on the first build

1. **`<Foundation/Foundation.h>` resolving to Agora** inside the stdlib build.
   Swift's build-script also builds swift-corelibs-foundation (a Swift module)
   for the tools; confirm the ObjC interop sources pick Agora's C headers.
2. **`[NSObject class]` linkage.** Whether libswiftCore hard-links
   `libagora-base` or references `NSObject` weakly.
3. **libdispatch unification.** The stdlib and concurrency use the Swift-enabled
   libdispatch built here; Agora's own code links `libagora-dispatch`. These must
   end up as one library at runtime. Unresolved, and the next real decision.

## 7. Not in scope here

- **SwiftPM / `swift test`.** Add upstream's unchanged
  `build-swiftpm-toolchain.sh` once the compiler and stdlib build cleanly.
- **The `ObjectiveC` overlay** (`Selector`, `#selector`) — not built for Linux
  (`OpenSwiftProject/swift#1`), independent of GNUstep.
- **The class-ABI staging plan** — S1–S6 are done and shipped (layout 2). See
  [`../SWIFT-GNUSTEP-CLASS-ABI.md`](../SWIFT-GNUSTEP-CLASS-ABI.md).
