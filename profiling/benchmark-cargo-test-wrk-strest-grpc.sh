#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
ITERATIONS="${ITERATIONS-1}"
DURATION="${DURATION-10s}"
CONNECTIONS="${CONNECTIONS-4}"
GRPC_STREAMS="${GRPC_STREAMS-4}"
HTTP_RPS="${HTTP_RPS-4000 8000 16000}"
GRPC_RPS="${GRPC_RPS-4000 8000}"
REQ_BODY_LEN="${REQ_BODY_LEN-10 200}"
PROXY_PORT_OUTBOUND=4140
PROXY_PORT_INBOUND=4143
SERVER_PORT=8080
PROFDIR=$(dirname "$0")
ID=$(date +"%Y%h%d_%Hh%Mm%Ss")

BRANCH_NAME=$(git symbolic-ref -q HEAD)
BRANCH_NAME=${BRANCH_NAME##refs/heads/}
BRANCH_NAME=${BRANCH_NAME:-HEAD}
BRANCH_NAME=$(echo $BRANCH_NAME | sed -e 's/\//-/g')
RUN_NAME="$BRANCH_NAME $ID Iter: $ITERATIONS Dur: $DURATION Conns: $CONNECTIONS Streams: $GRPC_STREAMS"

cd "$PROFDIR"
which actix-web-server || cargo install --path actix-web-server
which actix-web-server || ( echo "Please add ~/.cargo/bin to your PATH" ; exit 1 )
which wrk || ( echo "wrk not found: Compile the wrk binary from https://github.com/kinvolk/wrk2/ and move it to your PATH" ; exit 1 )
which strest-grpc || ( echo "strest-grpc not found: Compile binary from https://github.com/BuoyantIO/strest-grpc and move it to your PATH" ; exit 1 )

trap '{ killall iperf actix-web-server strest-grpc >& /dev/null; }' EXIT

echo "Test, target req/s, req len, branch, p999 latency (ms), GBit/s" > "summary.$RUN_NAME.txt"

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
  # wait for service to start
  until ss -tan | grep "LISTEN.*:$SERVER_PORT"
  do
    sleep 1
  done
  # wait for proxy to start
  until ss -tan | grep "LISTEN.*:$PROXY_PORT"
  do
    sleep 1
  done
  if [ "$MODE" = "TCP" ]; then
    ( iperf -t 6 -p "$PROXY_PORT" -c localhost || ( echo "iperf client failed"; true ) ) | tee "$NAME.$ID.txt"
    T=$(grep "/sec" "$NAME.$ID.txt" | cut -d' ' -f12)
    if [ -z "$T" ]; then
      T="0"
    fi
    echo "TCP $DIRECTION, 0, 0, $RUN_NAME, 0, $T" >> "summary.$RUN_NAME.txt"
  elif [ "$MODE" = "HTTP" ]; then
   for l in $REQ_BODY_LEN; do
    for r in $HTTP_RPS; do
      S=0
      for i in $(seq $ITERATIONS); do
        python -c "print('wrk.body = \"' + '_' * $l + '\"')" > wrk-report-tmp.lua
        cat wrk-report.lua >> wrk-report-tmp.lua
        wrk -d "$DURATION" -c "$CONNECTIONS" -t "$CONNECTIONS" -L -s wrk-report-tmp.lua -R "$r" -H 'Host: transparency.test.svc.cluster.local' "http://localhost:$PROXY_PORT/" | tee "$NAME$i-$r-rps.$ID.txt"
        T=$(tac "$NAME$i-$r-rps.$ID.txt" | grep -m 1 "^ .*0.99*" | cut -d':' -f2 | awk '{print $1}')
        if [ -z "$T" ]; then
          echo "No values for 0.9 percentiles found"
          exit 1
        fi
        S=$(python -c "print(max($S, $T))")
      done
      echo "HTTP $DIRECTION, $r, $l, $RUN_NAME, $S, 0" >> "summary.$RUN_NAME.txt"
    done
   done
  else
   for l in $REQ_BODY_LEN; do
    for r in $GRPC_RPS; do
      strest-grpc client --interval "$DURATION" --totalTargetRps "$r" --requestLengthPercentiles "100=$l" --streams "$GRPC_STREAMS" --connections "$CONNECTIONS" --iterations "$ITERATIONS" --address "localhost:$PROXY_PORT" --clientTimeout 1s | tee "$NAME-$r-rps.$ID.txt"
      T=$(grep -m 1 p999 "$NAME-$r-rps.$ID.txt" | cut -d':' -f2)
      echo "gRPC $DIRECTION, $r, $l, $RUN_NAME, $T, 0" >> "summary.$RUN_NAME.txt"
    done
   done
  fi
  # kill server
  kill $SPID
  # signal that proxy can terminate now
  echo F | nc localhost 7777 || true
  ) &
  PROFILING_SUPPORT_SERVER="127.0.0.1:$SERVER_PORT" cargo test --release profiling_setup -- --exact profiling_setup --nocapture
}

MODE=TCP DIRECTION=outbound NAME=tcpoutbound_bench PROXY_PORT=$PROXY_PORT_OUTBOUND single_benchmark_run
MODE=TCP DIRECTION=inbound NAME=tcpinbound_bench PROXY_PORT=$PROXY_PORT_INBOUND single_benchmark_run
MODE=HTTP DIRECTION=outbound NAME=http1outbound_bench PROXY_PORT=$PROXY_PORT_OUTBOUND single_benchmark_run
MODE=HTTP DIRECTION=inbound NAME=http1inbound_bench PROXY_PORT=$PROXY_PORT_INBOUND single_benchmark_run
MODE=gRPC DIRECTION=outbound NAME=grpcoutbound_bench PROXY_PORT=$PROXY_PORT_OUTBOUND single_benchmark_run
MODE=gRPC DIRECTION=inbound NAME=grpcinbound_bench PROXY_PORT=$PROXY_PORT_INBOUND single_benchmark_run
echo "Benchmark results (display with 'head -vn-0 *$ID.txt | less'):"
ls *$ID*.txt
echo SUMMARY:
cat "summary.$RUN_NAME.txt"
