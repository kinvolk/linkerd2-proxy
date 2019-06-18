#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
PROFDIR=$(dirname "$0")
cd "$PROFDIR"
rm ../target/release/profiling-* || true
RUSTFLAGS="-C debuginfo=2 -C lto=off" cargo test --release --no-run profiling_setup  # try lto=thin or =fat if they don't make perf miss calls
mv ../target/release/profiling-*[^.d] ../target/release/profiling-opt-and-dbg-symbols # ignore .d folder
