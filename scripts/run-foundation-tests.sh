#!/usr/bin/env bash
#
# run-foundation-tests.sh — P2 spike: build and run swift-foundation's own test
# suites against Agora.
#
#   swift-toolchain/scripts/run-foundation-tests.sh [TestFile.swift ...]
#   swift-toolchain/scripts/run-foundation-tests.sh --all
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
# The two remaining non-builds are recorded, not hidden: `PredicateTests` needs
# the `FoundationMacros` macro plugin, which this spike does not build (see
# SWIFT-FOUNDATION-P2-SPIKE.md), and `NotificationCenterTests` builds but has one
# failing assertion (subject matching for non-object literals) - see the summary
# and the spike's findings.
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
OUT="$SP/tests"
TESTS="$SRC/Tests/FoundationEssentialsTests"

FILES=()
for arg in "$@"; do
  case "$arg" in
    --all) FILES=("$TESTS"/*.swift) ;;
    -*)     echo "unknown option: $arg" >&2; exit 2 ;;
    *)      FILES+=("$arg") ;;
  esac
done
if [[ ${#FILES[@]} -eq 0 ]]; then
  FILES=(
    "$TESTS/DataTests.swift" "$TESTS/DataIOTests.swift" "$TESTS/DateTests.swift"
    "$TESTS/DateIntervalTests.swift" "$TESTS/DecimalTests.swift"
    "$TESTS/IndexPathTests.swift" "$TESTS/JSONEncoderTests.swift"
    "$TESTS/UUIDTests.swift" "$TESTS/URLTests.swift"
    "$TESTS/GregorianCalendarTests.swift" "$TESTS/StringTests.swift"
  )
fi

# Compiled into every suite: the helpers SwiftPM would have made module-internal.
SUPPORT=(
  "$SRC/Tests/TestSupport/Utilities.swift"
  "$TESTS/ResourceUtilities.swift"
)

# A suite that uses a type declared in another suite's *file*.  The borrowed file
# brings its own @Test declarations, so the run is filtered to the suite asked for.
cross_sources_for() {
  case "$(basename "$1" .swift)" in
    DataIOTests)              printf '%s\n' "$TESTS/DataTests.swift" ;;
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
    DataIOTests|URLTests|NotificationCenterTests|PropertyListEncoderTests)
      local n; n="$(basename "$1" .swift)"; echo "$n.$n" ;;
  esac
}

# `testData(forResource:)` on Linux is
# `dirname(argv[0])/swift-foundation_FoundationEssentialsTests-tool.resources/Resources`.
RESOURCE_BUNDLE="$OUT/swift-foundation_FoundationEssentialsTests-tool.resources"
mkdir -p "$RESOURCE_BUNDLE"
ln -sfn "$TESTS/Resources" "$RESOURCE_BUNDLE/Resources"

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
  -I "$SP/reexport/swift" -I "$SP/swift"
  -L "$SP/reexport/lib" -L "$SP/lib"
  -lFoundationEssentials -lFoundationInternationalization
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

  # A helper file is not a suite: ResourceUtilities.swift has no @Test.
  if [[ "$name" == "ResourceUtilities" ]]; then
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
echo "suites: $passed passed, $failed failed, $skipped did not build, $no_tests with no tests (logs in $OUT)"
