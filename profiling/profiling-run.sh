#!/bin/bash
# please allow perf for non-root users: echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid
# @TODO: check before starting the script?
# needs "cargo install inferno" for inferno-flamegraph, or git clone https://github.com/brendangregg/FlameGraph for flamegraph.pl
set -x
set -o errexit
set -o nounset
set -o pipefail
PROXY_PORT_OUTBOUND=4140
PROXY_PORT_INBOUND=4143
SERVER_PORT=8007
PROFDIR=$(dirname "$0")
cd "$PROFDIR"
cc -o server server.c

single_profiling_run () {
  (
  ./server -p $SERVER_PORT &
  SPID=$!
  # wait for proxy to start
  until ss -tan | grep "LISTEN.*:$PROXY_PORT"
  do
    sleep 1
  done
  ab -n 3000 -c 50 -H 'Host: transparency.test.svc.cluster.local' "http://127.0.0.1:$PROXY_PORT/server.c" | tee "$NAME.txt"
  # signal that proxy can terminate now
  echo F | ncat localhost 7777 || true
  # kill server
  kill $SPID
  ) &
  rm ./perf.data* || true
  PROFILING_SUPPORT_SERVER="127.0.0.1:$SERVER_PORT" perf record --call-graph dwarf ../target/release/profiling-*[^.d] --exact profiling_setup --nocapture # ignore .d folder
  perf script | inferno-collapse-perf > "out_$NAME.folded"  # separate step to be able to rerun flamegraph with another width
  inferno-flamegraph --width 4000 "out_$NAME.folded" > "flamegraph_$NAME.svg"  # or: flamegraph.pl instead of inferno-flamegraph
}

NAME=outbound PROXY_PORT=$PROXY_PORT_OUTBOUND single_profiling_run
NAME=inbound PROXY_PORT=$PROXY_PORT_INBOUND single_profiling_run
