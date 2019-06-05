#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail
rm ./target/release/profiling-* || true
RUSTFLAGS="-C debuginfo=2 -C lto=off" cargo test --release --no-run profiling_setup  # try lto=thin or =fat if they don't make perf miss calls
