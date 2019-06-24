#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
ITERATIONS="${ITERATIONS-1}"
DURATION="${DURATION-10s}"
CONNECTIONS="${CONNECTIONS-4}"
GRPC_STREAMS="${GRPC_STREAMS-4}"
HTTP_RPS="${HTTP_RPS-4000 7000}"
GRPC_RPS="${GRPC_RPS-4000 6000}"
REQ_BODY_LEN="${BODY_LEN-10 200}"
PROXY_PORT_OUTBOUND=4140
PROXY_PORT_INBOUND=4143
PROFDIR=$(dirname "$0")
ID=$(date +"%Y%h%d_%Hh%Mm%Ss")

BRANCH_NAME=$(git symbolic-ref -q HEAD)
BRANCH_NAME=${BRANCH_NAME##refs/heads/}
BRANCH_NAME=${BRANCH_NAME:-HEAD}
BRANCH_NAME=$(echo $BRANCH_NAME | sed -e 's/\//-/g')
RUN_NAME="$BRANCH_NAME $ID Iter: $ITERATIONS Dur: $DURATION Conns: $CONNECTIONS Streams: $GRPC_STREAMS"

cd "$PROFDIR"
which fortio || ( echo "fortio not found: Get the binary from  and have it available from your PATH" ; exit 1 )

trap '{ killall iperf fortio >& /dev/null; }' EXIT

echo "Test, target req/s, req len, branch, p999 latency (ms), GBit/s" > "summary.$RUN_NAME.txt"

single_benchmark_run () {
  (
  SERVER="fortio server -ui-path ''"
  if [ "$MODE" = "TCP" ]; then
    SERVER="iperf -s -p $SERVER_PORT"
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
    iperf -t 6 -p "$PROXY_PORT" -c 127.0.0.1 | tee "$NAME.$ID.txt"
    T=$(grep "/sec" "$NAME.$ID.txt" | cut -d' ' -f12)
    echo "TCP $DIRECTION, 0, 0, $RUN_NAME, 0, $T" >> "summary.$RUN_NAME.txt"
  else
    RPS="$HTTP_RPS"
    XARG=""
    if [ "$MODE" = "gRPC" ]; then
      RPS="$GRPC_RPS"
      XARG="-grpc -s $GRPC_STREAMS"
    fi
    for l in $REQ_BODY_LEN; do
     for r in $RPS; do
      S=0
      for i in $(seq $ITERATIONS); do
        fortio load $XARG -resolve 127.0.0.1 -c="$CONNECTIONS" -qps="$r" -t="$DURATION" -payload-size="$l" -labels="$RUN_NAME" -json="$NAME-$r-rps.$ID.json" -keepalive=false -H 'Host: transparency.test.svc.cluster.local' "localhost:$PROXY_PORT"
        T=$(tac "$NAME-$r-rps.$ID.json" | grep -m 1 Value | cut  -d':' -f2)
        if [ -z "$T" ]; then
          echo "No last percentile value found"
          exit 1
        fi
        S=$(python -c "print(max($S, $T*1000.0))")
      done
      echo "$MODE $DIRECTION, $r, $l, $RUN_NAME, $S, 0" >> "summary.$RUN_NAME.txt"
     done
    done
  fi
  # kill server
  kill $SPID
  # signal that proxy can terminate now
  echo F | nc 127.0.0.1 7777 || true
  ) &
  PROFILING_SUPPORT_SERVER="127.0.0.1:$SERVER_PORT" cargo test --release profiling_setup -- --exact profiling_setup --nocapture
}

MODE=TCP DIRECTION=outbound NAME=tcpoutbound_bench PROXY_PORT=$PROXY_PORT_OUTBOUND SERVER_PORT=8080 single_benchmark_run
MODE=TCP DIRECTION=inbound NAME=tcpinbound_bench PROXY_PORT=$PROXY_PORT_INBOUND SERVER_PORT=8080 single_benchmark_run
MODE=HTTP DIRECTION=outbound NAME=http1outbound_bench PROXY_PORT=$PROXY_PORT_OUTBOUND SERVER_PORT=8080 single_benchmark_run
MODE=HTTP DIRECTION=inbound NAME=http1inbound_bench PROXY_PORT=$PROXY_PORT_INBOUND SERVER_PORT=8080 single_benchmark_run
MODE=gRPC DIRECTION=outbound NAME=grpcoutbound_bench PROXY_PORT=$PROXY_PORT_OUTBOUND SERVER_PORT=8079 single_benchmark_run
MODE=gRPC DIRECTION=inbound NAME=grpcinbound_bench PROXY_PORT=$PROXY_PORT_INBOUND SERVER_PORT=8079 single_benchmark_run
echo "Benchmark results (display with 'head -vn-0 *$ID.txt *$ID.json | less' or compare them with ./plot.py):"
ls *$ID*.txt
echo SUMMARY:
cat "summary.$RUN_NAME.txt"
echo "Run 'fortio report' and open http://localhost:8080/ to display the HTTP/gRPC graphs"
