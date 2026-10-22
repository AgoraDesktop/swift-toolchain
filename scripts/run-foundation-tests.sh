#!/usr/bin/env bash
#
# run-foundation-tests.sh — P2 spike: build and run swift-foundation's own test
# suites against Agora.
#
#   swift-toolchain/scripts/run-foundation-tests.sh [TestFile.swift ...]
#   swift-toolchain/scripts/run-foundation-tests.sh --all
#   swift-toolchain/scripts/run-foundation-tests.sh --fi --all
#
# Two suites live here: `FoundationEssentialsTests` (the default) and
# `FoundationInternationalizationTests` (`--fi`: Locale, Calendar, TimeZone and
# the FormatStyle family, over ICU).
#
# No SwiftPM here, and swift-foundation's `Tests/` have no CMakeLists, so the
# harness is explicit: compile one test file at a time with the `Testing` library
# built by build-swift-testing.sh plus the writing/testing-enabled
# FoundationEssentials from build-swift-foundation.sh, link the swift-testing
# runner, and run it. One binary per file keeps a compile failure in one suite from
# hiding the results of the others.
#
# SwiftPM compiles the whole directory as *one module*, so the test files share
# things freely: `LargeDataTests` (declared in `DataTests.swift`) is extended from
# `DataIOTests.swift`, `URLTests` builds file trees with `FilePlayground`, and
# `JSONEncoderTests`/`PropertyListEncoderTests` read resources through
# `testData(forResource:)`.  Three things make a per-file compile equivalent:
#
#   * the shared helper sources are compiled in (`Tests/TestSupport/Utilities.swift`
#     and `FoundationEssentialsTests/ResourceUtilities.swift`);
#   * a suite that uses a type from another suite's file compiles that file too,
#     and passes a `--filter` so the borrowed suite's tests do not run here
#     (`CROSS_SOURCES` / `RUN_FILTER` below);
#   * the test resources are linked next to the binaries at the path
#     `testData` looks for (`swift-foundation_FoundationEssentialsTests-tool
#     .resources/Resources`), which is how the SwiftPM bundle is spelled on Linux.
#
# The predicate suites (`#Predicate`/`#Expression`) need swift-foundation's macro
# plugin; build it with build-foundation-macros.sh and point
# AGORA_FOUNDATION_MACROS_DIR at it (default: ~/.agora-swift/build/p2-foundation-macros).
# Without it those files do not build - that is the only remaining build gap, and
# it is a missing input rather than a defect.
#
# Inputs (all produced by the other spike scripts):
#   ~/.agora-swift/build/p2-foundation-testing   FE/FI with -enable-testing + reexport Foundation
#   ~/.agora-swift/build/p2-swift-testing        Testing, TestingMacros (host build)
#
# `import Foundation` here is the *re-export* module (FoundationEssentials +
# FoundationInternationalization), which is P3's first shape.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

T="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
BO="$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN"
SRC="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation"
ICU="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation-icu/icuSources/include"
SHIMS="$SRC/Sources/_FoundationCShims/include"
SP="${AGORA_FOUNDATION_SPIKE_DIR:-$OPEN_SWIFT_BUILD_ROOT/p2-foundation-testing}"
TB="${AGORA_SWIFT_TESTING_BUILD_DIR:-$OPEN_SWIFT_BUILD_ROOT/p2-swift-testing}"
SUITE="FoundationEssentialsTests"
# swift-foundation's macro plugin (`#Predicate`/`#Expression`/`#Bundle`), built by
# build-foundation-macros.sh.  A library plugin: it runs inside the compiler
# process, so it is a host build and is loaded with -load-plugin-library.
MACROS="${AGORA_FOUNDATION_MACROS_DIR:-$OPEN_SWIFT_BUILD_ROOT/p2-foundation-macros}"
MACRO_PLUGIN="$MACROS/lib/libFoundationMacros.so"

want_all=0
explicit=()
for arg in "$@"; do
  case "$arg" in
    --fi)  SUITE="FoundationInternationalizationTests" ;;
    --all) want_all=1 ;;
    -*)    echo "unknown option: $arg" >&2; exit 2 ;;
    *)     explicit+=("$arg") ;;
  esac
done

TESTS="$SRC/Tests/$SUITE"
OUT="$SP/tests/$SUITE"

# Files that are support code rather than suites (no @Test), plus one XCTest
# performance suite that is `#if FOUNDATION_FRAMEWORK` and never builds here.
is_helper() {
  case "$(basename "$1" .swift)" in
    ResourceUtilities|CalendarPerformanceTests|DiscreteFormatStyleTestUtilities|CurrentInternationalizationPreferencesActor)
      return 0 ;;
  esac
  return 1
}

FILES=()
if (( want_all )); then
  for f in "$TESTS"/*.swift "$TESTS"/*/*.swift; do
    [[ -f "$f" ]] || continue
    is_helper "$f" || FILES+=("$f")
  done
else
  FILES=("${explicit[@]}")
fi
if [[ ${#FILES[@]} -eq 0 ]]; then
  if [[ "$SUITE" == "FoundationEssentialsTests" ]]; then
    FILES=(
      "$TESTS/DataTests.swift" "$TESTS/DataIOTests.swift" "$TESTS/DateTests.swift"
      "$TESTS/DateIntervalTests.swift" "$TESTS/DecimalTests.swift"
      "$TESTS/IndexPathTests.swift" "$TESTS/JSONEncoderTests.swift"
      "$TESTS/UUIDTests.swift" "$TESTS/URLTests.swift"
      "$TESTS/GregorianCalendarTests.swift" "$TESTS/StringTests.swift"
    )
  else
    for f in "$TESTS"/*.swift "$TESTS"/*/*.swift; do
      [[ -f "$f" ]] || continue
      is_helper "$f" || FILES+=("$f")
    done
  fi
fi

# Compiled into every binary: the helpers SwiftPM would have made module-internal.
SUPPORT=("$SRC/Tests/TestSupport/Utilities.swift")
if [[ "$SUITE" == "FoundationEssentialsTests" ]]; then
  SUPPORT+=("$TESTS/ResourceUtilities.swift")          # testData(forResource:)
else
  # `usingCurrentInternationalizationPreferences { }` and the discrete-format
  # helpers: support code every FI suite may reach for.
  SUPPORT+=("$TESTS/CurrentInternationalizationPreferencesActor.swift"
            "$TESTS/Formatting/DiscreteFormatStyleTestUtilities.swift")
fi

# A suite that uses a type declared in another suite's *file*.  The borrowed file
# brings its own @Test declarations, so the run is filtered to the suite asked for.
cross_sources_for() {
  case "$(basename "$1" .swift)" in
    DataIOTests)              printf '%s\n' "$TESTS/DataTests.swift" ;;
    FileManagerTests)         printf '%s\n' "$TESTS/FileManager/FilePlayground.swift" ;;
    URLTests)                 printf '%s\n' "$TESTS/FileManager/FilePlayground.swift"
                              printf '%s\n' "$TESTS/FileManager/FileManagerTests.swift" ;;
    NotificationCenterTests)  printf '%s\n' "$TESTS/NotificationCenterMessageTests.swift" ;;
    PropertyListEncoderTests) printf '%s\n' "$TESTS/JSONEncoderTests.swift" ;;
  esac
}

# The run filter for such a suite: swift-testing matches against the test ID,
# `<module>.<SuiteType>/<test>`, and the module is the binary's name.  The suite
# *type* in these files is named after the file, so `<name>.<name>` selects
# exactly the suite asked for and none of the borrowed one (a display name such
# as "URL" would match the module name `URLTests` and run everything).
run_filter_for() {
  case "$(basename "$1" .swift)" in
    DataIOTests|URLTests|NotificationCenterTests|PropertyListEncoderTests|FileManagerTests)
      local n; n="$(basename "$1" .swift)"; echo "$n.$n" ;;
  esac
}

# `testData(forResource:)` on Linux is
# `dirname(argv[0])/swift-foundation_FoundationEssentialsTests-tool.resources/Resources`.
RESOURCE_BUNDLE="$OUT/swift-foundation_FoundationEssentialsTests-tool.resources"
if [[ -d "$TESTS/Resources" ]]; then
  mkdir -p "$RESOURCE_BUNDLE"
  ln -sfn "$TESTS/Resources" "$RESOURCE_BUNDLE/Resources"
fi

mkdir -p "$OUT"
cat > "$OUT/Runner.swift" <<'EOF'
import Testing
import Glibc

@main
struct TestRunner {
  static func main() async {
    let code: CInt = await Testing.__swiftPMEntryPoint()
    exit(code)
  }
}
EOF

COMMON=(
  -I "$TB/swift" -L "$TB/lib"
  -lTesting -l_TestingInterop -l_TestDiscovery -l_TestingInternals
  # `import Foundation` here is the *spike's* re-export (FE + FI, no Clang
  # Foundation).  The shipped P3 `Foundation` re-exports Agora's Clang module as
  # well, and FoundationEssentials' package `Bundle` stub then collides with
  # Agora's `NSBundle` (which imports as `Bundle`) under `@testable import.
  -I "$SP/reexport/swift" -I "$SP/swift"
  -L "$SP/reexport/lib" -L "$SP/lib"
  # FoundationInternationalization *first*: it provides the concrete
  # `_icuStringEncodingConvert`, which FoundationEssentials declares `dynamic`
  # with a nil stub.  ELF symbol interposition takes the first definition in the
  # executable's dependency order, so the order here is the difference between
  # `String.data(using: .japaneseEUC)` working and answering nil.
  -lFoundationInternationalization -lFoundationEssentials
  -l_FoundationCollections -l_FoundationCShims -l_FoundationICU
  -load-plugin-library "$TB/lib/swift/host/plugins/libTestingMacros.so"
  -Xcc "-fmodule-map-file=$SHIMS/module.modulemap"
  -Xcc "-fmodule-map-file=$ICU/_foundation_unicode/module.modulemap"
  -Xcc -I"$ICU" -Xcc -I"$SHIMS"
  -Xcc "-fmodule-map-file=$AGORA_ROOT/swift-interop-probe/agora-modules/module.modulemap"
  -Xcc -I"$AGORA_PREFIX/include" -Xcc -Wno-incomplete-umbrella
  -L "$AGORA_PREFIX/lib"
  -Xlinker -rpath -Xlinker "$TB/lib"
  -Xlinker -rpath -Xlinker "$SP/lib"
  -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib"
)
# The predicate suites need the Foundation macro plugin; everything else is
# unaffected by it.  Say so once instead of failing per file if it is missing.
if [[ -f "$MACRO_PLUGIN" ]]; then
  COMMON+=(-load-plugin-library "$MACRO_PLUGIN")
fi

# Compile: the compiler runs on the host runtime (the wrapper puts it first), and
# the macro plugin is a host build, so the host stdlib is on the path; the target
# stdlib must NOT be, or the compiler picks up the wrong libswiftCore.
export LD_LIBRARY_PATH="$BO/lib/swift/linux:$TB/lib:$SP/lib:$SP/reexport/lib:$AGORA_PREFIX/lib"

passed=0
failed=0
skipped=0
no_tests=0
for file in "${FILES[@]}"; do
  name="$(basename "$file" .swift)"
  bin="$OUT/$name"
  log="$OUT/$name.build.log"

  if is_helper "$file"; then
    continue
  fi

  extra=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && extra+=("$dep")
  done < <(cross_sources_for "$file")

  if ! "$T/bin/swiftc" -O -o "$bin" "$OUT/Runner.swift" "$file" \
        "${SUPPORT[@]}" "${extra[@]}" "${COMMON[@]}" >"$log" 2>&1; then
    printf '%-34s %s\n' "$name" "BUILD FAILED"
    skipped=$((skipped + 1))
    continue
  fi

  # Run only the suite this binary was built for, when the extra sources brought
  # another one along (a `--filter`/`--skip` pair over the test IDs).
  run_args=()
  filter="$(run_filter_for "$file")"
  [[ -n "$filter" ]] && run_args+=(--filter "$filter")

  # Run: the test binary is target code, so the target stdlib leads.
  status=0
  LD_LIBRARY_PATH="$T/lib/swift/linux:$TB/lib:$SP/lib:$AGORA_PREFIX/lib" "$bin" \
        "${run_args[@]}" >"$OUT/$name.run.log" 2>&1 || status=$?
  # swift-testing's "no tests found" exit code (EX_UNAVAILABLE): the file's tests
  # are inside a platform guard (`#if FOUNDATION_FRAMEWORK`).  Not a failure.
  if [[ "$status" -eq 69 ]] && grep -aq 'Test run with 0 tests' "$OUT/$name.run.log"; then
    printf '%-34s %s\n' "$name" "no tests on this platform"
    no_tests=$((no_tests + 1))
    continue
  fi
  if [[ "$status" -eq 0 ]]; then
    summary="$(grep -aE 'Test run with|tests? in .* suites?' "$OUT/$name.run.log" | tail -1)"
    if [[ -n "$filter" ]] && grep -aq 'Test run with 0 tests' "$OUT/$name.run.log"; then
      printf '%-34s %s\n' "$name" "FAILED (--filter \"$filter\" selected no tests)"
      failed=$((failed + 1))
      continue
    fi
    printf '%-34s PASS  %s\n' "$name" "$summary"
    passed=$((passed + 1))
  else
    printf '%-34s %s\n' "$name" "FAILED"
    { grep -aE '✘|failed' "$OUT/$name.run.log" | head -5 | sed 's/^/    /'; } || true
    failed=$((failed + 1))
  fi
done

echo
echo "${SUITE}: $passed passed, $failed failed, $skipped did not build, $no_tests with no tests"
echo "(logs in $OUT)"
