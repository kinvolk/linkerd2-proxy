#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
PROXY_PORT_OUTBOUND=4140
PROXY_PORT_INBOUND=4143
SERVER_PORT=8080
PROFDIR=$(dirname "$0")
ID=$(date +"%Y%h%d_%Hh%Mm%Ss")

cd "$PROFDIR"
which actix-web-server || cargo install --path actix-web-server
which actix-web-server || ( echo "Please add ~/.cargo/bin to your PATH" ; exit 1 )
which wrk || ( echo "wrk not found: Compile the wrk binary from https://github.com/kinvolk/wrk2/ and move it to your PATH" ; exit 1 )
ls libmemory_profiler.so memory-profiler-cli || ( curl -L -O https://github.com/nokia/memory-profiler/releases/download/0.3.0/memory-profiler-x86_64-unknown-linux-gnu.tgz ; tar xf memory-profiler-x86_64-unknown-linux-gnu.tgz ; rm memory-profiler-x86_64-unknown-linux-gnu.tgz )

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
  if [ "$MODE" = "TCP" ]; then
    iperf -t 6 -p "$PROXY_PORT" -c localhost | tee "$NAME.$ID.txt"
  else
    wrk -L -s wrk-report.lua -R 4500 -H 'Host: transparency.test.svc.cluster.local' "http://127.0.0.1:$PROXY_PORT/" | tee "$NAME.$ID.txt"
  fi
  # signal that proxy can terminate now
  echo F | nc localhost 7777 || true
  # kill server
  kill $SPID
  ) &
  rm memory-profiling_*.dat || true
  PROFILING_SUPPORT_SERVER="127.0.0.1:$SERVER_PORT" LD_PRELOAD=./libmemory_profiler.so ../target/release/profiling-*[^.d] --exact profiling_setup --nocapture # ignore .d folder
  mv memory-profiling_*.dat "$NAME.$ID.heap.dat"
  ./memory-profiler-cli export-heaptrack "$NAME.$ID.heap.dat" --output "$NAME.$ID.heaptrack.dat"
}

MODE=TCP NAME=tcpoutbound PROXY_PORT=$PROXY_PORT_OUTBOUND single_profiling_run
MODE=TCP NAME=tcpinbound PROXY_PORT=$PROXY_PORT_INBOUND single_profiling_run
MODE=HTTP NAME=outbound PROXY_PORT=$PROXY_PORT_OUTBOUND single_profiling_run
MODE=HTTP NAME=inbound PROXY_PORT=$PROXY_PORT_INBOUND single_profiling_run
echo "a) Run './memory-profiler-cli server CHANGEME.$ID.heap.dat' and open http://localhost:8080/ to browse the memory graphs or,"
echo "b) run 'heaptrack -a CHANGEME.$ID.heaptrack.dat' to open the heaptrack files for a detailed view."
echo "(Replace CHANGEME with inbound, outbound, tcpinbound, tcpoutbound.)"
