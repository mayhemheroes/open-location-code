#!/usr/bin/env bash
#
# mayhem/build.sh — build the go-fuzz harness for the Go implementation of
# open-location-code as a sanitized libFuzzer binary (OSS-Fuzz Go path:
# go-fuzz-build -libfuzzer + clang link), plus the pre-built test runners.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV (under /opt/toolchains).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
# The first (online) build populates $GOMODCACHE; GOPROXY reads the file proxy
# at $GOMODCACHE/cache/download FIRST, network only as a cache-miss fallback.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASan-only for the libFuzzer link.
: "${SANITIZER_FLAGS=-fsanitize=address}"
# Debug-info contract (§6.2 item 10): keep symbols/DWARF on the fuzz build.
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS GO_DEBUG_FLAGS MAYHEM_JOBS

# Go 1.25 defaults to DWARF 5; Mayhem triage needs DWARF < 4 (§6.2 item 10).
# nodwarf5 keeps the Go compile units at DWARF <= 4, and the cgo C units
# (runtime/cgo's gcc_*.c, compiled by clang-19 which defaults to DWARF 5)
# are pinned to DWARF 3 via CGO_CFLAGS.
export GOEXPERIMENT="${GOEXPERIMENT:-nodwarf5}"
export CGO_CFLAGS="${CGO_CFLAGS:--g -gdwarf-3 -O2}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:--g -gdwarf-3 -O2}"

# Resolve modules offline-first from the in-image cache; network only as a fallback.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

cd "$SRC"
go version

TARGET="encode-decode-fuzz"
HARNESS_DIR="go"    # module github.com/google/open-location-code/go, legacy func Fuzz in olc_gofuzz.go

mkdir -p "$SRC/mayhem-build"
echo "=== building $TARGET (go-fuzz-build -libfuzzer) ==="
(
  cd "$SRC/$HARNESS_DIR"
  # go-fuzz-build needs go-fuzz-dep on the module graph (resolves from cache offline).
  go get github.com/dvyukov/go-fuzz/go-fuzz-dep
  GOFLAGS="$GOFLAGS $GO_DEBUG_FLAGS" go-fuzz-build -libfuzzer -o "$SRC/mayhem-build/$TARGET.a"
)
# Link the go-fuzz archive into a libFuzzer binary with clang (ASan).
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem-build/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# Pre-build the Go test suite with the project's NORMAL flags (test.sh only RUNS it).
# CGO + external linking → dynamically linked test binary (LD_PRELOAD-visible).
echo "=== building Go test runner ==="
(
  cd "$SRC/$HARNESS_DIR"
  CGO_ENABLED=1 go test -c -ldflags '-linkmode=external' -o "$SRC/mayhem-build/olc-go.test" .
)
echo "built $SRC/mayhem-build/olc-go.test"

# The Python test suite (python/openlocationcode_test.py) is stdlib-only and runs
# directly from the source tree — nothing to pre-build.
echo "build.sh complete"
