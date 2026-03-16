#!/usr/bin/env bash
# ============================================================================
# dev-nifi-up.sh — Builds NiFi from source and starts a 3-node local cluster
#                  plus a standalone instance for testing both modes at once.
#
# Usage:   /opt/nifi-dev-cluster/dev-nifi-up.sh                    (full build + start)
#          /opt/nifi-dev-cluster/dev-nifi-up.sh --skip-build       (reuse build)
#          /opt/nifi-dev-cluster/dev-nifi-up.sh --clean-nx         (nuke Nx caches + build)
#
# Requirements:
#   - JDK 21+
#   - Maven (mvnw wrapper is used from the repo root)
#   - keytool (ships with JDK)
#   - ~4 GB free RAM (4 NiFi JVMs: 3 cluster + 1 standalone)
#
# What it does:
#   1. Builds nifi-assembly (produces the distributable zip)
#   2. Stops any previously-running nodes
#   3. Creates 3 cluster + 1 standalone NiFi installs under /opt/nifi-dev-cluster/nodes/
#   4. Generates per-node keystores + shared truststore via keytool
#   5. Configures nodes 1-3 for clustering (unique IPs, ports, embedded ZK, etc.)
#   6. Configures node 4 (standalone) with no cluster settings
#   7. Sets single-user credentials (admin / adminadminadmin)
#   8. Starts node 1 (with embedded ZooKeeper), waits for ZK, starts 2, 3, and standalone
#   9. Prints access URLs and log locations
#
# Node identity:
#   Each node uses a distinct loopback IP:
#     Node 1: 127.0.0.1    Node 2: 127.0.0.2    Node 3: 127.0.0.3
#     Standalone: 127.0.0.4
#   Linux routes the entire 127.0.0.0/8 block to the loopback interface.
#
# Caveats:
#   - Browser access: https://127.0.0.1:9443/nifi (cluster), https://127.0.0.4:9446/nifi (standalone)
#   - Self-signed certs — browser will warn about untrusted certificate.
#   - Embedded ZK runs only on node 1. If node 1 dies, ZK is unavailable.
#   - Single-user auth: each node authenticates independently.
#   - First startup is slower because NiFi unpacks NARs.
# ============================================================================
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Point REPO_ROOT at the NiFi source checkout
REPO_ROOT="${NIFI_REPO_ROOT:-$HOME/IdeaProjects/nifi}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$SCRIPT_DIR/nodes"
CERTS_DIR="$SCRIPT_DIR/certs"

# Auto-detect version from the root pom.xml
NIFI_VERSION="$(sed -n '/<parent>/,/<\/parent>/!{ s/.*<version>\(.*\)<\/version>.*/\1/p; }' "$REPO_ROOT/pom.xml" | head -1)"
if [ -z "$NIFI_VERSION" ]; then
    echo "ERROR: Could not detect NiFi version from $REPO_ROOT/pom.xml"
    exit 1
fi
echo "Detected NiFi version: $NIFI_VERSION"
ASSEMBLY_ZIP="$REPO_ROOT/nifi-assembly/target/nifi-${NIFI_VERSION}-bin.zip"
NIFI_DIR_NAME="nifi-${NIFI_VERSION}"

NUM_NODES=3

# Each node binds to a distinct loopback IP so cluster protocol, load balancing,
# and HTTPS all have unique identities. This prevents TLS hostname confusion
# that occurs when all nodes use "localhost".
NODE_IPS=("127.0.0.1" "127.0.0.2" "127.0.0.3")

# Standalone instance uses a 4th loopback IP — completely independent from the cluster
STANDALONE_IP="127.0.0.4"
STANDALONE_HTTPS_PORT=9446

# Total nodes: 3 cluster + 1 standalone
TOTAL_NODES=4

# Credentials for browser login (single-user provider)
ADMIN_USER="admin"
ADMIN_PASS="adminadminadmin"

# Shared sensitive props key — must be identical on all cluster nodes, otherwise
# nodes cannot decrypt each other's sensitive property values in the shared flow.
SENSITIVE_PROPS_KEY="dev-cluster-key-12chars"

# Per-node port assignments — cluster protocol, LB, and remote sockets bind to
# 0.0.0.0 regardless of the node address, so each node needs distinct ports.
# HTTPS binds to the node-specific IP so could share a port, but we use distinct
# ports for clarity and easier log/browser identification.
#   Node 1 (127.0.0.1): HTTPS=9443, protocol=11443, LB=16342, remote=10443
#   Node 2 (127.0.0.2): HTTPS=9444, protocol=11444, LB=16343, remote=10444
#   Node 3 (127.0.0.3): HTTPS=9445, protocol=11445, LB=16344, remote=10445
#   Standalone (127.0.0.4): HTTPS=9446 (no cluster ports needed)
HTTPS_PORTS=(9443 9444 9445)
PROTOCOL_PORTS=(11443 11444 11445)
LB_PORTS=(16342 16343 16344)
REMOTE_PORTS=(10443 10444 10445)

# ZooKeeper ports (only node 1 runs embedded ZK; all nodes connect to it)
ZK_CLIENT_PORT=2181
ZK_PEER_PORT=2888
ZK_ELECTION_PORT=3888

# TLS passwords (for dev use only — not production)
KEYSTORE_PASS="devclusterpass"
TRUSTSTORE_PASS="devclusterpass"

# ============================================================================
# Parse arguments
# ============================================================================

SKIP_BUILD=false
CLEAN_NX=false
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --clean-nx) CLEAN_NX=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ============================================================================
# Helper functions
# ============================================================================

log() {
    echo ""
    echo "======================================================================"
    echo "  $1"
    echo "======================================================================"
}

wait_for_port() {
    local host="$1"
    local port="$2"
    local timeout="${3:-120}"
    local elapsed=0
    while ! (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q "${host}:${port} \|:${port} "; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "  ERROR: Timed out waiting for $host:$port after ${timeout}s"
            return 1
        fi
    done
    echo "  $host:$port is listening (waited ${elapsed}s)"
}

wait_for_nifi_api() {
    local url="$1"
    local timeout="${2:-300}"
    local elapsed=0
    echo "  Waiting for NiFi API at $url ..."
    while true; do
        local code
        code=$(curl -sk -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
        # Any HTTP response (even 401/403) means NiFi is up
        if [[ "$code" =~ ^[2-5] ]]; then
            echo "  NiFi API responding (HTTP $code) at $url (waited ${elapsed}s)"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "  ERROR: Timed out waiting for NiFi API at $url after ${timeout}s"
            return 1
        fi
    done
}

nifi_home() {
    local node_num="$1"
    echo "$CLUSTER_DIR/node${node_num}/$NIFI_DIR_NAME"
}

# Modifies a key=value property in a NiFi properties file.
# Handles the case where the value might contain characters special to sed.
set_prop() {
    local file="$1"
    local key="$2"
    local value="$3"
    # Use | as sed delimiter since values don't contain it
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
}

# ============================================================================
# Step 0: Stop any existing cluster nodes and kill stale processes
# ============================================================================
log "Stopping any existing nodes"

for i in $(seq 1 "$TOTAL_NODES"); do
    NIFI_HOME="$(nifi_home "$i")"
    if [ -x "$NIFI_HOME/bin/nifi.sh" ]; then
        echo "  Stopping node $i ..."
        "$NIFI_HOME/bin/nifi.sh" stop 2>/dev/null || true
    fi
done

# Give processes a moment to exit cleanly
sleep 3

# Kill any lingering NiFi java processes from current or previous cluster locations.
# Previous runs may have used /tmp/nifi-dev-cluster; we kill those too.
# We filter to java processes only to avoid killing this script itself.
for pattern in "$CLUSTER_DIR" "/tmp/nifi-dev-cluster"; do
    if pgrep -f "java.*${pattern}" >/dev/null 2>&1; then
        echo "  Killing lingering Java processes matching: $pattern"
        pkill -9 -f "java.*${pattern}" 2>/dev/null || true
    fi
done
sleep 2

# ============================================================================
# Step 1: Build from source
# ============================================================================
if [ "$SKIP_BUILD" = true ]; then
    log "Skipping build (--skip-build)"
    if [ ! -f "$ASSEMBLY_ZIP" ]; then
        echo "ERROR: Assembly zip not found at $ASSEMBLY_ZIP"
        echo "       Run without --skip-build first."
        exit 1
    fi
else
    log "Cleaning stale build caches (prevents serving old UI)"
    cd "$REPO_ROOT"
    if [ "$CLEAN_NX" = true ]; then
        echo "  Cleaning Nx caches (--clean-nx) ..."
        rm -rfv "$HOME/.nx"
        rm -rfv nifi-frontend/src/main/frontend/.nx
        rm -rfv nifi-frontend/target
    fi
    # Always purge UI + NAR artifacts to prevent stale frontend bundles
    rm -rfv nifi-frontend/src/main/frontend/dist
    rm -rfv nifi-framework-bundle/nifi-framework/nifi-web/nifi-ui/target
    rm -rfv nifi-framework-bundle/nifi-server-nar/target
    rm -rfv nifi-assembly/target

    log "Building NiFi assembly from source (this takes a while)"
    ./mvnw install -Dmaven.test.skip=true -pl nifi-assembly -am \
        -T1C \
        -Dspotless.check.skip=true \
        -Drat.skip=true \
        -Denforcer.skip=true
    if [ ! -f "$ASSEMBLY_ZIP" ]; then
        echo "ERROR: Build completed but assembly zip not found at $ASSEMBLY_ZIP"
        exit 1
    fi
fi

# ============================================================================
# Step 2: Clean and unpack 3 NiFi instances
# ============================================================================
log "Preparing $TOTAL_NODES NiFi instances (${NUM_NODES} cluster + 1 standalone)"

rm -rf "$CLUSTER_DIR"
mkdir -p "$CLUSTER_DIR"

for i in $(seq 1 "$TOTAL_NODES"); do
    if [ "$i" -le "$NUM_NODES" ]; then
        echo "  Unpacking cluster node $i ..."
    else
        echo "  Unpacking standalone node ..."
    fi
    NODE_DIR="$CLUSTER_DIR/node${i}"
    mkdir -p "$NODE_DIR"
    unzip -q "$ASSEMBLY_ZIP" -d "$NODE_DIR"
done

# ============================================================================
# Step 3: Generate TLS certificates
# ============================================================================
log "Generating TLS certificates for cluster communication"

# Each node gets its own keystore with a self-signed cert whose CN and SAN
# match that node's loopback IP (127.0.0.x). All node certs are imported
# into a single shared truststore so every node trusts every other node.

rm -rf "$CERTS_DIR"
mkdir -p "$CERTS_DIR"

for i in $(seq 1 "$NUM_NODES"); do
    IDX=$((i - 1))
    NODE_IP="${NODE_IPS[$IDX]}"
    ALIAS="node${i}"

    echo "  Generating keystore for node $i (IP=$NODE_IP, alias=$ALIAS) ..."
    keytool -genkeypair \
        -alias "$ALIAS" \
        -keyalg EC -groupname secp256r1 -sigalg SHA256withECDSA \
        -validity 3650 \
        -dname "CN=${NODE_IP}, OU=Node${i}, O=NiFi, L=Local, ST=Dev, C=US" \
        -keystore "$CERTS_DIR/keystore-node${i}.p12" \
        -storetype PKCS12 -storepass "$KEYSTORE_PASS" \
        -ext "SAN=ip:${NODE_IP},dns:localhost" \
        -ext "KeyUsage=digitalSignature,keyEncipherment" \
        -ext "ExtendedKeyUsage=serverAuth,clientAuth"

    echo "  Exporting certificate for node $i ..."
    keytool -exportcert \
        -alias "$ALIAS" \
        -keystore "$CERTS_DIR/keystore-node${i}.p12" -storetype PKCS12 -storepass "$KEYSTORE_PASS" \
        -rfc -file "$CERTS_DIR/node${i}-cert.pem"

    echo "  Importing node $i certificate into shared truststore ..."
    keytool -importcert \
        -alias "$ALIAS" \
        -file "$CERTS_DIR/node${i}-cert.pem" \
        -keystore "$CERTS_DIR/truststore.p12" -storetype PKCS12 -storepass "$TRUSTSTORE_PASS" \
        -noprompt
done

echo ""
echo "  Validating truststore contents:"
keytool -list -keystore "$CERTS_DIR/truststore.p12" -storetype PKCS12 -storepass "$TRUSTSTORE_PASS" 2>/dev/null
echo ""
echo "  Certificates generated successfully (${NUM_NODES} keystores + 1 shared truststore)."

# ============================================================================
# Step 4: Configure each node
# ============================================================================
log "Configuring cluster nodes"

# ZooKeeper connect string — all nodes connect to the embedded ZK on node 1
ZK_CONNECT="${NODE_IPS[0]}:${ZK_CLIENT_PORT}"

# Build the proxy host list — NiFi needs this so cluster coordinator can forward
# requests between nodes without hitting the proxy host validation.
# Include both IP:port and localhost:port variants for browser access.
PROXY_HOSTS=""
for i in $(seq 0 $((NUM_NODES - 1))); do
    if [ -n "$PROXY_HOSTS" ]; then
        PROXY_HOSTS="${PROXY_HOSTS},"
    fi
    PROXY_HOSTS="${PROXY_HOSTS}${NODE_IPS[$i]}:${HTTPS_PORTS[$i]}"
done
# Also allow browser access via localhost (resolves to 127.0.0.1)
PROXY_HOSTS="${PROXY_HOSTS},localhost:${HTTPS_PORTS[0]}"

for i in $(seq 1 "$NUM_NODES"); do
    echo "  Configuring node $i ..."
    NIFI_HOME="$(nifi_home "$i")"
    CONF_DIR="$NIFI_HOME/conf"
    PROPS_FILE="$CONF_DIR/nifi.properties"

    IDX=$((i - 1))
    NODE_IP="${NODE_IPS[$IDX]}"

    # Each node gets its own keystore; all share the same truststore
    cp "$CERTS_DIR/keystore-node${i}.p12" "$CONF_DIR/keystore.p12"
    cp "$CERTS_DIR/truststore.p12" "$CONF_DIR/truststore.p12"

    # ---- Web server ----
    # Bind HTTPS to this node's unique loopback IP
    set_prop "$PROPS_FILE" "nifi.web.https.host" "$NODE_IP"
    set_prop "$PROPS_FILE" "nifi.web.https.port" "${HTTPS_PORTS[$IDX]}"
    set_prop "$PROPS_FILE" "nifi.web.proxy.host" "$PROXY_HOSTS"

    # ---- Security / TLS ----
    set_prop "$PROPS_FILE" "nifi.security.keystore" "./conf/keystore.p12"
    set_prop "$PROPS_FILE" "nifi.security.keystoreType" "PKCS12"
    set_prop "$PROPS_FILE" "nifi.security.keystorePasswd" "$KEYSTORE_PASS"
    set_prop "$PROPS_FILE" "nifi.security.keyPasswd" "$KEYSTORE_PASS"
    set_prop "$PROPS_FILE" "nifi.security.truststore" "./conf/truststore.p12"
    set_prop "$PROPS_FILE" "nifi.security.truststoreType" "PKCS12"
    set_prop "$PROPS_FILE" "nifi.security.truststorePasswd" "$TRUSTSTORE_PASS"

    # Sensitive properties key — must match on all nodes
    set_prop "$PROPS_FILE" "nifi.sensitive.props.key" "$SENSITIVE_PROPS_KEY"

    # Single-user login (default for NiFi 2.x)
    set_prop "$PROPS_FILE" "nifi.security.user.authorizer" "single-user-authorizer"
    set_prop "$PROPS_FILE" "nifi.security.user.login.identity.provider" "single-user-provider"

    # ---- Cluster node ----
    # Use this node's unique loopback IP as the cluster node address
    set_prop "$PROPS_FILE" "nifi.cluster.is.node" "true"
    set_prop "$PROPS_FILE" "nifi.cluster.node.address" "$NODE_IP"
    set_prop "$PROPS_FILE" "nifi.cluster.node.protocol.port" "${PROTOCOL_PORTS[$IDX]}"

    # Flow election: wait up to 30s or until all 3 nodes vote
    set_prop "$PROPS_FILE" "nifi.cluster.flow.election.max.wait.time" "30 secs"
    set_prop "$PROPS_FILE" "nifi.cluster.flow.election.max.candidates" "$NUM_NODES"

    # ---- Load balancing ----
    set_prop "$PROPS_FILE" "nifi.cluster.load.balance.host" "$NODE_IP"
    set_prop "$PROPS_FILE" "nifi.cluster.load.balance.port" "${LB_PORTS[$IDX]}"

    # ---- Remote input ----
    set_prop "$PROPS_FILE" "nifi.remote.input.host" "$NODE_IP"
    set_prop "$PROPS_FILE" "nifi.remote.input.socket.port" "${REMOTE_PORTS[$IDX]}"

    # ---- ZooKeeper ----
    set_prop "$PROPS_FILE" "nifi.zookeeper.connect.string" "$ZK_CONNECT"

    # Only node 1 starts the embedded ZooKeeper server
    if [ "$i" -eq 1 ]; then
        set_prop "$PROPS_FILE" "nifi.state.management.embedded.zookeeper.start" "true"
    else
        set_prop "$PROPS_FILE" "nifi.state.management.embedded.zookeeper.start" "false"
    fi

    # ---- zookeeper.properties ----
    # Configure embedded ZK with a single-server ensemble (node 1 only).
    ZK_PROPS="$CONF_DIR/zookeeper.properties"
    sed -i "s|^dataDir=.*|dataDir=./state/zookeeper|" "$ZK_PROPS"

    # Set client port
    if grep -q "^clientPort=" "$ZK_PROPS"; then
        sed -i "s|^clientPort=.*|clientPort=${ZK_CLIENT_PORT}|" "$ZK_PROPS"
    else
        echo "clientPort=${ZK_CLIENT_PORT}" >> "$ZK_PROPS"
    fi

    # Set server line (single-server ZK ensemble)
    sed -i '/^server\./d' "$ZK_PROPS"
    echo "server.1=${NODE_IPS[0]}:${ZK_PEER_PORT}:${ZK_ELECTION_PORT};${ZK_CLIENT_PORT}" >> "$ZK_PROPS"

    # Create the myid file for node 1 (ZK server identity)
    if [ "$i" -eq 1 ]; then
        mkdir -p "$NIFI_HOME/state/zookeeper"
        echo "1" > "$NIFI_HOME/state/zookeeper/myid"
    fi

    # ---- state-management.xml ----
    # The ZK state provider has its own Connect String property (separate from nifi.properties).
    # We need to set it so the cluster state provider can reach ZooKeeper.
    STATE_MGMT="$CONF_DIR/state-management.xml"
    sed -i 's|<property name="Connect String"></property>|<property name="Connect String">'"$ZK_CONNECT"'</property>|' "$STATE_MGMT"

    # ---- bootstrap.conf: management server ----
    # The management server auto-selects from 52020-52050 but binds to 127.0.0.1,
    # which conflicts when multiple nodes share the loopback. Set an explicit
    # address per node using the node's own IP to avoid port collisions.
    BOOTSTRAP_CONF="$CONF_DIR/bootstrap.conf"
    MGMT_PORT=$((52020 + IDX))
    echo "management.server.address=http://${NODE_IP}:${MGMT_PORT}" >> "$BOOTSTRAP_CONF"

    # ---- Set single-user credentials ----
    "$NIFI_HOME/bin/nifi.sh" set-single-user-credentials "$ADMIN_USER" "$ADMIN_PASS"
done

# ---- Configure standalone node (node 4) ----
echo "  Configuring standalone node (node $TOTAL_NODES) ..."
NIFI_HOME_SA="$(nifi_home "$TOTAL_NODES")"
CONF_DIR_SA="$NIFI_HOME_SA/conf"
PROPS_FILE_SA="$CONF_DIR_SA/nifi.properties"

# Bind HTTPS to the standalone IP — NiFi will auto-generate its own keystore/truststore
set_prop "$PROPS_FILE_SA" "nifi.web.https.host" "$STANDALONE_IP"
set_prop "$PROPS_FILE_SA" "nifi.web.https.port" "$STANDALONE_HTTPS_PORT"
set_prop "$PROPS_FILE_SA" "nifi.web.proxy.host" "${STANDALONE_IP}:${STANDALONE_HTTPS_PORT}"

# Sensitive properties key (standalone can use its own)
set_prop "$PROPS_FILE_SA" "nifi.sensitive.props.key" "$SENSITIVE_PROPS_KEY"

# Single-user login
set_prop "$PROPS_FILE_SA" "nifi.security.user.authorizer" "single-user-authorizer"
set_prop "$PROPS_FILE_SA" "nifi.security.user.login.identity.provider" "single-user-provider"

# Explicitly disable clustering
set_prop "$PROPS_FILE_SA" "nifi.cluster.is.node" "false"

# Management server on its own IP to avoid conflicts
BOOTSTRAP_CONF_SA="$CONF_DIR_SA/bootstrap.conf"
echo "management.server.address=http://${STANDALONE_IP}:52023" >> "$BOOTSTRAP_CONF_SA"

# Set credentials
"$NIFI_HOME_SA/bin/nifi.sh" set-single-user-credentials "$ADMIN_USER" "$ADMIN_PASS"

echo "  Configuration complete."

# ============================================================================
# Step 5: Start the cluster
# ============================================================================
log "Starting node 1 (with embedded ZooKeeper)"

"$(nifi_home 1)/bin/nifi.sh" start

echo "  Waiting for ZooKeeper on port $ZK_CLIENT_PORT ..."
wait_for_port "${NODE_IPS[0]}" "$ZK_CLIENT_PORT" 120

echo "  Waiting for node 1 API ..."
wait_for_nifi_api "https://${NODE_IPS[0]}:${HTTPS_PORTS[0]}/nifi-api/access/config" 300

log "Starting nodes 2, 3, and standalone"

for i in 2 3; do
    echo "  Starting cluster node $i ..."
    "$(nifi_home "$i")/bin/nifi.sh" start
done

echo "  Starting standalone node ..."
"$(nifi_home "$TOTAL_NODES")/bin/nifi.sh" start

for i in 2 3; do
    IDX=$((i - 1))
    echo "  Waiting for cluster node $i API ..."
    wait_for_nifi_api "https://${NODE_IPS[$IDX]}:${HTTPS_PORTS[$IDX]}/nifi-api/access/config" 300
done

echo "  Waiting for standalone node API ..."
wait_for_nifi_api "https://${STANDALONE_IP}:${STANDALONE_HTTPS_PORT}/nifi-api/access/config" 300

# ============================================================================
# Step 6: Print summary
# ============================================================================
log "All NiFi instances are running!"

echo ""
echo "  ┌─────────────────────────────────────────────────────────────────────┐"
echo "  │  CLUSTER                                                          │"
echo "  │                                                                   │"
echo "  │  Node 1:  https://${NODE_IPS[0]}:${HTTPS_PORTS[0]}/nifi              │"
echo "  │  Node 2:  https://${NODE_IPS[1]}:${HTTPS_PORTS[1]}/nifi              │"
echo "  │  Node 3:  https://${NODE_IPS[2]}:${HTTPS_PORTS[2]}/nifi              │"
echo "  │                                                                   │"
echo "  │  STANDALONE                                                       │"
echo "  │                                                                   │"
echo "  │  https://${STANDALONE_IP}:${STANDALONE_HTTPS_PORT}/nifi                          │"
echo "  │                                                                   │"
echo "  │  Username: ${ADMIN_USER}                                              │"
echo "  │  Password: ${ADMIN_PASS}                                   │"
echo "  └─────────────────────────────────────────────────────────────────────┘"

echo ""
echo "  Log locations:"
for i in $(seq 1 "$NUM_NODES"); do
    echo "    Cluster node $i: $(nifi_home "$i")/logs/nifi-app.log"
done
echo "    Standalone:      $(nifi_home "$TOTAL_NODES")/logs/nifi-app.log"

echo ""
echo "  To stop everything:"
echo "    /opt/nifi-dev-cluster/dev-nifi-down.sh"
echo ""
echo "  To rebuild and restart:"
echo "    /opt/nifi-dev-cluster/dev-nifi-down.sh && /opt/nifi-dev-cluster/dev-nifi-up.sh --skip-build"
echo ""
