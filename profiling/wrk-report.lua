function done(summary, latency, requests)
    print(string.format("Total Requests: %d", summary.requests))
    print(string.format("HTTP errors: %d", summary.errors.status))
    print(string.format("Requests timed out: %d", summary.errors.timeout)) 
    print(string.format("Bytes received: %d", summary.bytes))
    print(string.format("Socket connect errors: %d", summary.errors.connect))
    print(string.format("Socket read errors: %d", summary.errors.read))
    print(string.format("Socket write errors: %d", summary.errors.write))
end
