#!/usr/bin/env python3
import pandas as pd
import matplotlib
import matplotlib.pyplot as plt
import argparse

parser = argparse.ArgumentParser(description='Plot two CSV results for comparison.')
parser.add_argument('input1', type=str, help='First CSV result file')
parser.add_argument('input2', type=str, help='Second CSV result file')
parser.add_argument('outputprefix', type=str, help='Prefix to use for the PNG graph files')
args = parser.parse_args()

g = pd.concat([pd.read_csv(args.input1, index_col=["Test", " target req/s"]), pd.read_csv(args.input2, index_col=["Test", " target req/s"])])
g.groupby(level=["Test", " target req/s"])

only_gbits = g[[" branch", " GBit/s"]][ g[" GBit/s"] > 0 ]
rearrange_gbits = only_gbits.pivot_table(index = ['Test', ' target req/s'], columns = " branch", values = " GBit/s")
rearrange_gbits.plot(kind='bar', title="Throughput (GBit/s)", figsize=(10, 8))
plt.xticks(rotation = 0)
outfile_gbits = args.outputprefix + "gbits.png"
print("Save graph to", outfile_gbits)
plt.savefig(outfile_gbits, bbox_inches='tight')

only_latency = g[[" branch", " p999 latency (ms)"]][ g[" p999 latency (ms)"] > 0 ]
rearrange_latency = only_latency.pivot_table(index = ['Test', ' target req/s'], columns = " branch", values = " p999 latency (ms)")
rearrange_latency.plot(kind='bar', logy=True, title="p999 Latency (ms)", figsize=(13, 3), fontsize=7)
plt.xticks(rotation = 0)
outfile_latency = args.outputprefix + "latency.png"
print("Save graph to", outfile_latency)
plt.savefig(outfile_latency, bbox_inches='tight')

print("Plotted sucessfully")
