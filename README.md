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

The reverse traceroute services need no configuration in your env file. The
API key for the reverse traceroute API is provided by M-Lab and read by
revtr-sidecar from `./autonode/revtr-api-key`, next to the other files that
`register-node` writes to `./autonode`.

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

### ICMP identifier partitioning

revtrvp and traceroute-caller both run scamper in the host network namespace.
If two scamper instances use the same ICMP identifier, echo replies can be
delivered to the wrong instance. The two never overlap:

| Service           | ICMP identifiers  | Why                                                                                               |
|-------------------|-------------------|---------------------------------------------------------------------------------------------------|
| revtrvp           | `[0, 32768)`      | `SCAMPER_ICMP_ID_BASE=0` / `SCAMPER_ICMP_ID_RANGE=32768`, read by the patched scamper in its image |
| traceroute-caller | `[32768, 65536)`  | stock scamper sets bit `0x8000` on the identifier for `tracelb -P icmp-echo` (MDA mode)           |

In its default mode (`-scamper.trace-type=regular`) traceroute-caller sends
UDP probes, which do not use an ICMP identifier at all.
