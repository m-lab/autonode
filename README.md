# autonode

Documentation on how to set up a host-managed M-Lab server is located in [the
Wiki of this
repository](https://github.com/m-lab/autonode/wiki/Host%E2%80%90managed-Deployments).

## Deploying

Copy the `env` template and fill in your values:

```bash
cp env env.local
# edit env.local with your ORGANIZATION, API_KEY, IPV4, etc.
```

Start the full stack (NDT + reverse traceroute):

```bash
docker compose --env-file env.local --profile ndt --profile revtr up -d
```

Start without reverse traceroute:

```bash
docker compose --env-file env.local --profile ndt up -d
```

**Tip:** to avoid repeating the flags on every invocation, create a `.env` file
(gitignored) in this directory:

```bash
cat > .env << 'EOF'
COMPOSE_PROFILES=ndt,revtr
EOF
# Then simply:
docker compose --env-file env.local up -d
```

## Reverse Traceroute

When the `revtr` profile is active, two additional containers start automatically
from their published images — no extra repositories or build steps required:

- **revtrvp** ([ghcr.io/neu-sns/revtrvp](https://github.com/NEU-SNS/revtrvp)) —
  a scamper-based vantage point that runs on ndt-server's public IP and executes
  spoofed-ICMP probing instructions from the revtr controller.
- **revtr-sidecar** ([ghcr.io/neu-sns/revtr-sidecar](https://github.com/NEU-SNS/revtr-sidecar)) —
  watches completed NDT connections and asks the revtr controller to run a reverse
  traceroute from each client back to this node.

### Configuration

Add the following to your `env.local`:

```bash
# API key for the reverse traceroute gRPC API (obtain from the revtr team).
REVTR_API_KEY=

# Hostname and port of the reverse traceroute API server.
REVTR_HOSTNAME=revtr.ccs.neu.edu
REVTR_GRPC_PORT=9999

# Sampling rate: 1 out of every N NDT connections triggers a reverse traceroute.
# Use 1 to trigger on every connection.
REVTR_SAMPLING=1
```

Place a `plvp.config` file in `./revtrvp/plvp.config` (relative to this
directory). Minimal example:

```yaml
local:
    interface: <your-interface>   # e.g. eth0
    host: 'plcontroller.revtr.ccs.neu.edu'
    port: 4380
scamper:
    binpath: '/usr/local/bin/scamper'
    port: 4381
```

### ICMP identifier partitioning (optional)

When revtrvp and traceroute-caller run on the same host they both spawn scamper
instances that share the host network namespace. To prevent them from picking the
same ICMP identifier, build the patched scamper binary and configure the ID space
partitioning in `env.local`:

```bash
# Use the patched binary built from the scamper ICMP-ID partitioning patch.
SCAMPER_BIN=/usr/local/bin/scamper-anticollision

# traceroute-caller takes the upper half of the ID space; revtrvp takes the lower.
SCAMPER_ICMP_ID_BASE=32768
SCAMPER_ICMP_ID_RANGE=32768
```

Without this, both instances use the default `getpid() & 0xffff` identifier
selection, which may result in occasional ICMP probe collisions.
