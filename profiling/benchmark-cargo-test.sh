#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
PROXY_PORT_OUTBOUND=4140
PROXY_PORT_INBOUND=4143
SERVER_PORT=8080
PROFDIR=$(dirname "$0")
ID=$(date +"%Y%h%d_%Hh%Mm%Ss")

BRANCH_NAME=$(git symbolic-ref -q HEAD)
BRANCH_NAME=${BRANCH_NAME##refs/heads/}
BRANCH_NAME=${BRANCH_NAME:-HEAD}
BRANCH_NAME=$(echo $BRANCH_NAME | sed -e 's/\//-/g')

cd "$PROFDIR"
which actix-web-server || cargo install --path actix-web-server
which actix-web-server || ( echo "Please add ~/.cargo/bin to your PATH" ; exit 1 )
which wrk || ( echo "wrk not found: Compile the wrk binary from https://github.com/kinvolk/wrk2/ and move it to your PATH" ; exit 1 )
which strest-grpc || ( echo "strest-grpc not found: Compile binary from https://github.com/BuoyantIO/strest-grpc and move it to your PATH" ; exit 1 )

trap '{ killall iperf actix-web-server strest-grpc >& /dev/null; }' EXIT

echo "Test, target req/s, branch, p999 latency (ms), GBit/s" > "summary.$BRANCH_NAME.$ID.txt"

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
    T=$(grep "/sec" "$NAME.$ID.txt" | cut -d' ' -f12)
    echo "TCP $DIRECTION, 0, $BRANCH_NAME, 0, $T" >> "summary.$BRANCH_NAME.$ID.txt"
  elif [ "$MODE" = "HTTP" ]; then
    for r in 4000 8000 16000; do
      S=0
      for i in 1 2 3 4 5; do
        wrk -d 10s -c 4 -t 4 -L -s wrk-report.lua -R $r -H 'Host: transparency.test.svc.cluster.local' "http://127.0.0.1:$PROXY_PORT/" | tee "$NAME$i-$r-rps.$ID.txt"
        T=$(tac "$NAME$i-$r-rps.$ID.txt" | grep -m 1 0.999 | cut -d':' -f2 | awk '{print $1}')
        S=$(python -c "print(max($S, $T))")
      done
      echo "HTTP $DIRECTION, $r, $BRANCH_NAME, $S, 0" >> "summary.$BRANCH_NAME.$ID.txt"
    done
  else
    for r in 4000 8000; do
      strest-grpc client --interval 10s --totalTargetRps $r --streams 4 --connections 4 --iterations 5 --address "127.0.0.1:$PROXY_PORT" --clientTimeout 1s | tee "$NAME-$r-rps.$ID.txt"
      T=$(grep -m 1 p999 "$NAME-$r-rps.$ID.txt" | cut -d':' -f2)
      echo "gRPC $DIRECTION, $r, $BRANCH_NAME, $T, 0" >> "summary.$BRANCH_NAME.$ID.txt"
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
# outbount gRPC is not working
MODE=gRPC DIRECTION=inbound NAME=grpcinbound_bench PROXY_PORT=$PROXY_PORT_INBOUND single_benchmark_run
echo "Benchmark results (display with 'head -vn-0 *$ID.txt | less'):"
ls *$ID*.txt
echo SUMMARY:
cat "summary.$BRANCH_NAME.$ID.txt"
