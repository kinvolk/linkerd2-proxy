#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
PROXY_PORT_OUTBOUND=4140
PROXY_PORT_INBOUND=4143
SERVER_PORT=8080
PROFDIR=$(dirname "$0")

typeset -i PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid)
if [ "$PARANOID" -ne "-1" ]; then
  echo "To capture kernel events please run: echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid"
  exit 1
fi

cd "$PROFDIR"
which inferno-collapse-perf inferno-flamegraph || cargo install inferno
which actix-web-server || cargo install --path actix-web-server

trap '{ killall actix-web-server >& /dev/null; }' EXIT

single_profiling_run () {
  (
  actix-web-server &
  SPID=$!
  # wait for proxy to start
  until ss -tan | grep "LISTEN.*:$PROXY_PORT"
  do
    sleep 1
  done
  ab -n 3000 -c 50 -H 'Host: transparency.test.svc.cluster.local' "http://127.0.0.1:$PROXY_PORT/" | tee "$NAME.txt"
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
