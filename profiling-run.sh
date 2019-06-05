#!/bin/bash
# please allow perf for non-root users: echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid
# @TODO: check before starting the script?
# needs "cargo install inferno" for inferno-flamegraph, or git clone https://github.com/brendangregg/FlameGraph for flamegraph.pl
set -x
set -o errexit
set -o nounset
set -o pipefail

cc -o server server.c
(
./server -p 8000 &
SPID=$!
sleep 5
ab -n 100 -c 32 -H 'Host: transparency.test.svc.cluster.local' "http://127.0.0.1:4140/server.c" # outbound
ab -n 100 -c 32 -H 'Host: transparency.test.svc.cluster.local' "http://127.0.0.1:4143/server.c" # inbound
echo F | ncat localhost 7777 || true
kill $SPID
) &

rm ./perf.data* || true
PROFILING_SUPPORT_SERVER="127.0.0.1:8000" perf record --call-graph dwarf target/release/profiling-*[^.d] --exact profiling_setup --nocapture # ignore .d folder
perf script | inferno-collapse-perf > out.folded  # separate step to be able to rerun flamegraph with another width
cat out.folded | inferno-flamegraph --width 4000 > flamegraph.svg  # or: flamegraph.pl instead of inferno-flamegraph
