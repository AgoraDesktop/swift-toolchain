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
for file in "${FILES[@]}"; do
  name="$(basename "$file" .swift)"
  bin="$OUT/$name"
  log="$OUT/$name.build.log"
  if ! "$T/bin/swiftc" -O -o "$bin" "$OUT/Runner.swift" "$file" \
        "$SRC/Tests/TestSupport/Utilities.swift" "${COMMON[@]}" >"$log" 2>&1; then
    printf '%-34s %s\n' "$name" "BUILD FAILED"
    skipped=$((skipped + 1))
    continue
  fi
  # Run: the test binary is target code, so the target stdlib leads.
  if LD_LIBRARY_PATH="$T/lib/swift/linux:$TB/lib:$SP/lib:$AGORA_PREFIX/lib" "$bin" \
        >"$OUT/$name.run.log" 2>&1; then
    summary="$(grep -E 'Test run with|tests? in .* suites?' "$OUT/$name.run.log" | tail -1)"
    printf '%-34s PASS  %s\n' "$name" "$summary"
    passed=$((passed + 1))
  else
    printf '%-34s %s\n' "$name" "FAILED"
    { grep -E '✘|failed' "$OUT/$name.run.log" | head -5 | sed 's/^/    /'; } || true
    failed=$((failed + 1))
  fi
done

echo
echo "suites: $passed passed, $failed failed, $skipped did not build (logs in $OUT)"
