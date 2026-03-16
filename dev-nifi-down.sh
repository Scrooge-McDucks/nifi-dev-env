#!/usr/bin/env bash
# ============================================================================
# dev-nifi-down.sh — Stops all nodes (3 cluster + 1 standalone).
#
# Usage:   /opt/nifi-dev-cluster/dev-nifi-down.sh
#          /opt/nifi-dev-cluster/dev-nifi-down.sh --clean   (also removes node dirs + certs)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$SCRIPT_DIR/nodes"
NUM_NODES=4

CLEAN=false
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

echo "Stopping local NiFi dev environment..."

for i in $(seq 1 "$NUM_NODES"); do
    # Auto-detect the nifi-* directory inside each node folder
    NIFI_SH="$(find "$CLUSTER_DIR/node${i}" -maxdepth 2 -name "nifi.sh" -path "*/bin/*" 2>/dev/null | head -1)"
    if [ -n "$NIFI_SH" ] && [ -x "$NIFI_SH" ]; then
        echo "  Stopping node $i ..."
        "$NIFI_SH" stop 2>/dev/null || true
    else
        echo "  Node $i not found (skipping)"
    fi
done

# Wait for graceful shutdown
sleep 3

# Kill any lingering NiFi java processes from current or previous cluster locations
for pattern in "$CLUSTER_DIR" "/tmp/nifi-dev-cluster"; do
    if pgrep -f "java.*${pattern}" >/dev/null 2>&1; then
        echo "  Killing lingering Java processes matching: $pattern"
        pkill -9 -f "java.*${pattern}" 2>/dev/null || true
    fi
done
sleep 2

if [ "$CLEAN" = true ]; then
    echo "  Removing node directories..."
    rm -rf "$CLUSTER_DIR"
    echo "  Removing certificates..."
    rm -rf "$SCRIPT_DIR/certs"
fi

echo "All NiFi instances stopped."
