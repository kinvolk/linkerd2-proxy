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
which strest-grpc || ( echo "strest-grpc not found: Compile binary from https://github.com/BuoyantIO/strest-grpc and move it to your PATH" ; exit 1 )

trap '{ killall iperf actix-web-server strest-grpc >& /dev/null; }' EXIT

single_benchmark_run () {
  (
  SERVER=actix-web-server
  if [ "$MODE" = "TCP" ]; then
    SERVER="iperf -s -p $SERVER_PORT"
  elif [ "$MODE" = "gRPC" ]; then
    SERVER="strest-grpc server --address 127.0.0.1:$SERVER_PORT"
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
  elif [ "$MODE" = "HTTP" ]; then
    for i in 1 2; do
      wrk -L -s wrk-report.lua -R 4500 -H 'Host: transparency.test.svc.cluster.local' "http://127.0.0.1:$PROXY_PORT/" | tee "$NAME$i.$ID.txt"
    done
  else
    strest-grpc client --totalTargetRps 4000 --streams 10 --connections 10 --iterations 2 --address "127.0.0.1:$PROXY_PORT" --clientTimeout 1s | tee "$NAME.$ID.txt"
  fi
  # signal that proxy can terminate now
  echo F | nc localhost 7777 || true
  # kill server
  kill $SPID
  ) &
  rm ./perf.data* || true
  PROFILING_SUPPORT_SERVER="127.0.0.1:$SERVER_PORT" cargo test --release profiling_setup -- --exact profiling_setup --nocapture
}

MODE=TCP NAME=tcpoutbound_bench PROXY_PORT=$PROXY_PORT_OUTBOUND single_benchmark_run
MODE=TCP NAME=tcpinbound_bench PROXY_PORT=$PROXY_PORT_INBOUND single_benchmark_run
MODE=HTTP NAME=outbound_bench PROXY_PORT=$PROXY_PORT_OUTBOUND single_benchmark_run
MODE=HTTP NAME=inbound_bench PROXY_PORT=$PROXY_PORT_INBOUND single_benchmark_run
# outbount gRPC is not working # MODE=gRPC NAME=grpcoutbound_bench PROXY_PORT=$PROXY_PORT_OUTBOUND single_benchmark_run
MODE=gRPC NAME=grpcinbound_bench PROXY_PORT=$PROXY_PORT_INBOUND single_benchmark_run
echo "Benchmark results:"
ls *$ID*.txt
