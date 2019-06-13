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
which inferno-collapse-perf inferno-flamegraph actix-web-server || ( echo "Please add ~/.cargo/bin to your PATH" ; exit 1 )
which wrk || ( echo "wrk not found: Compile the wrk binary from https://github.com/kinvolk/wrk2/ and move it to your PATH" ; exit 1 )
./wss.pl -h 2> /dev/null && RET=$? || RET=$?
if [ $RET -eq 2 ]; then
  echo "wss.pl can not start: Install the perl-Time-HiRes package of your distribution"
  exit 1
fi

trap '{ killall iperf actix-web-server >& /dev/null; }' EXIT

single_profiling_run () {
  (
  SERVER=actix-web-server
  if [ "$MODE" = "TCP" ]; then
    SERVER="iperf -s -p $SERVER_PORT"
  fi
  $SERVER &
  SPID=$!
  # wait for proxy to start
  until ss -tan | grep "LISTEN.*:$PROXY_PORT"
  do
    sleep 1
  done
  LINKERD_TEST_BIN=$(ls ../target/release/profiling-*[^.d])
  ( ./wss.pl $(pgrep -f -x "$LINKERD_TEST_BIN --exact profiling_setup --nocapture") 6 | tee "wss_$NAME.txt" ) &
  if [ "$MODE" = "TCP" ]; then
    iperf -t 6 -p "$PROXY_PORT" -c localhost | tee "$NAME.txt"
  else
    wrk -L -s wrk-report.lua -R 4500 -H 'Host: transparency.test.svc.cluster.local' "http://127.0.0.1:$PROXY_PORT/" | tee "$NAME.txt"
  fi
  while pgrep wss.pl; do
    sleep 1
  done
  # signal that proxy can terminate now
  echo F | nc localhost 7777 || true
  # kill server
  kill $SPID
  ) &
  rm ./perf.data* || true
  PROFILING_SUPPORT_SERVER="127.0.0.1:$SERVER_PORT" perf record -F 2000 --call-graph dwarf ../target/release/profiling-*[^.d] --exact profiling_setup --nocapture # ignore .d folder
  perf script | inferno-collapse-perf > "out_$NAME.folded"  # separate step to be able to rerun flamegraph with another width
  inferno-flamegraph --width 4000 "out_$NAME.folded" > "flamegraph_$NAME.svg"  # or: flamegraph.pl instead of inferno-flamegraph
}

MODE=TCP NAME=tcpoutbound PROXY_PORT=$PROXY_PORT_OUTBOUND single_profiling_run
MODE=TCP NAME=tcpinbound PROXY_PORT=$PROXY_PORT_INBOUND single_profiling_run
MODE=HTTP NAME=outbound PROXY_PORT=$PROXY_PORT_OUTBOUND single_profiling_run
MODE=HTTP NAME=inbound PROXY_PORT=$PROXY_PORT_INBOUND single_profiling_run
