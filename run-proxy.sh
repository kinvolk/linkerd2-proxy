#!/bin/sh
set -eu

if [ -z "${LINKERD2_PROXY_IDENTITY_DISABLED:-}" ]; then
    /usr/lib/linkerd/linkerd2-proxy-identity \
        -dir "$LINKERD2_PROXY_IDENTITY_DIR" \
        -name "$LINKERD2_PROXY_IDENTITY_LOCAL_NAME"
fi

export LD_PRELOAD="/usr/lib/libtcmalloc.so.4" HEAPPROFILE="/tmp/profile"

exec /usr/lib/linkerd/linkerd2-proxy
