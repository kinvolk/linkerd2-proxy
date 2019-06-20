# Benchmark

The benchmark script applies HTTP, gRPC, and TCP workloads with
the benchmark utilities wrk2, strest-grpc, and iperf.
The script logs to files and generates a summary CSV with the
99th percentile latencies (or GBit/s for TCP).

## Compare two branches

Two summary CSVs can be compared by plotting them as graphs:

```
$ cd profiling/
$ ./benchmark-cargo-test.sh ; git checkout master && ./benchmark-cargo-test.sh
$ ./plot.py summary.mybranch.2019Jun19_15h13m12s.txt summary.master.2019Jun19_15h34m26s.txt mybranch-vs-master-
$ eog mybranch-vs-master-*png
```

Another option is to quickly compare in textual form:
```
$ git diff --no-index --word-diff summary.mybranch.2019Jun19_15h13m12s.txt summary.master.2019Jun19_15h34m26s.txt
```

# Profiling

Profiling needs to have a build with debug symbols but optimizations.
The build script will generate such a binary but needs to be run
manually before the profiling if the source code changed.

The profiling happens while the benchmark workload is applied.

## Trace function calls with perf

Trace function call stacks (2000 per second) and generate flamegraphs:

```
$ ./profiling-build.sh # if needed
$ ./profiling-run.sh
$ firefox/chrome *svg  # view flamegraph
```


## Trace memory allocations

Trace heap memory allocations and generate flamegraphs:

```
$ ./profiling-build.sh # if needed
$ ./profiling-heap.sh
$ heaptrack -a ….heaptrack.dat  # view report
```

## Log memory usage

Report program memory and actively used part of it:

```
$ ./profiling-build.sh # if needed
$ ./profiling-wss.sh
```
