# NiFi Dev Environment

Scripts for spinning up a local 3-node NiFi cluster plus a standalone instance from source. Useful for testing clustered features (replication, primary-node failover, load balancing) and standalone behavior side-by-side.

## What it does

`dev-nifi-up.sh` builds NiFi from source, then creates and starts 4 NiFi instances:

| Instance   | IP        | URL                              |
|------------|-----------|----------------------------------|
| Cluster 1  | 127.0.0.1 | https://127.0.0.1:9443/nifi      |
| Cluster 2  | 127.0.0.2 | https://127.0.0.2:9444/nifi      |
| Cluster 3  | 127.0.0.3 | https://127.0.0.3:9445/nifi      |
| Standalone | 127.0.0.4 | https://127.0.0.4:9446/nifi      |

Login: `admin` / `adminadminadmin`

Each node binds to a distinct loopback IP (Linux routes the entire 127.0.0.0/8 block to lo). Self-signed TLS certs are generated per-node with a shared truststore. Embedded ZooKeeper runs on node 1.

## Requirements

- JDK 21+
- Maven (uses the `mvnw` wrapper from the NiFi repo)
- ~4 GB free RAM (4 NiFi JVMs)
- Linux (uses loopback IP aliases)

## Usage

```bash
# Full build + start (takes a while on first run)
/opt/nifi-dev-cluster/dev-nifi-up.sh

# Reuse a previous build (skip Maven)
/opt/nifi-dev-cluster/dev-nifi-up.sh --skip-build

# Nuke Nx caches before building (fixes stale frontend)
/opt/nifi-dev-cluster/dev-nifi-up.sh --clean-nx

# Stop everything
/opt/nifi-dev-cluster/dev-nifi-down.sh

# Stop and remove all node dirs + certs
/opt/nifi-dev-cluster/dev-nifi-down.sh --clean
```

## Configuration

By default the scripts look for the NiFi source checkout at `$HOME/IdeaProjects/nifi`. Override with:

```bash
export NIFI_REPO_ROOT=/path/to/nifi
```

The NiFi version is auto-detected from the root `pom.xml`.

## How it works

1. Builds `nifi-assembly` from source (produces the distributable zip)
2. Stops any previously running nodes and kills stale processes
3. Unpacks 4 NiFi instances under `nodes/`
4. Generates per-node keystores + shared truststore via `keytool`
5. Configures nodes 1-3 for clustering (unique IPs, ports, embedded ZK)
6. Configures node 4 as standalone (no cluster settings)
7. Sets single-user credentials
8. Starts node 1, waits for ZooKeeper, then starts the rest
