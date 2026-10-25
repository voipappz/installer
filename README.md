# VoIPAppz node installer

One command installs one VoIP node: the private `va-crystal` image, its stack in
`/opt/voipappz`, registration with your mothership, and the running container.
The mothership itself is a different machine and a different installer
(`voipappz/mothership`).

## Run it — one example, start to finish

On a clean Ubuntu 22.04 or 24.04 machine:

```console
$ curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh | sh

VoIPAppz VoIP node installer

1/6  Docker
  installing Docker

2/6  Platform image
  Image source:
    1) pull ghcr.io/voipappz/node:latest from the GitHub registry (ghcr.io) (needs a GitHub user + a classic token with read:packages)
    2) download the latest image archive from Amazon S3
    3) load a docker-save archive (.tar or .tar.gz) from a local path or URL
  Choose 1, 2 or 3 [1]:            ← Enter is enough
  GitHub user: <you>
  GitHub token with read:packages (input hidden):
  logging in to the GitHub registry (ghcr.io) with a temporary Docker config
  pulling ghcr.io/voipappz/node:latest

3/6  Node stack
  installed the stack and verified its in-container CLI

4/6  va.yaml
  Node name [node-45d979c7-…]:     ← Enter, or type a name
  Available network interfaces:
    1. 10.0.0.10  eth0 (detected)
  Choose internal IP [1]:          ← Enter
  External IP [10.0.0.10]:         ← Enter, or the public address
  Mothership URL [https://cloud.voipappz.io]:   ← Enter, or your own
  broker derived from the mothership URL: https://cloud.voipappz.io/nats

5/6  Registration
  Account token (input hidden; empty = use email + password):   ← paste, or Enter
  registering node 45d979c7-… through the existing CLI

6/6  VoIP plane
  va-voip is healthy

VoIPAppz installation complete
  node:      45d979c7-68c0-4c63-a86f-a229e0dfeab9
  va.yaml:   /opt/voipappz/config/va.yaml -> /tmp/node.yaml (Docker bind mount)
  container: va-voip
  health:    http://127.0.0.1:4000/health
```

That is the whole install. Four Enters, a mothership URL and an Account token.
The Account token is the Basic key of your mothership Account — leave it empty
and it asks for e-mail and password instead.

## Everyday commands

The node is **one container, `va-voip`**, started with `docker run` — there is
no Compose file, because the image carries the whole node:

```sh
docker ps --filter name=va-voip           # is it up?
docker exec va-voip voipappz health       # is it well? names anything down
docker logs -f va-voip                    # what is it doing?
docker restart va-voip                    # after editing config/va.yaml
docker stop va-voip                       # stop it (config and data stay)
docker start va-voip                      # start it again
```

If the container is gone rather than stopped — a failed upgrade, a removed
container, a host that came up without it — `sh install.sh --start-only`
recreates it from what `/opt/voipappz` already holds (its `va.yaml`, its
`.env`, its pinned CA bundle). It downloads nothing, registers nothing and
writes nothing: it is the last step of the install, on its own, and it waits
for the node to answer its health check before it reports success.

### Ports

Kamailio, FreeSWITCH and the node agent run together in the container **on the
host network**, so these are the host's own ports. Open the public ones to your
carriers and phones; the loopback ones need no firewall rule.

| Port | | Used by | Reachable on |
|---|---|---|---|
| `5060` | UDP | Kamailio — carriers and phones | all interfaces |
| `5070` | UDP+TCP | FreeSWITCH, phones | the node's address |
| `5061` | TCP | FreeSWITCH, phones over **TLS** | the node's address |
| `5066` | TCP | FreeSWITCH, WebRTC over WebSocket | the node's address |
| `5090` | UDP+TCP | FreeSWITCH, carriers | the node's address |
| `5081` | TCP | FreeSWITCH, carriers over **TLS** | the node's address |
| `8443` | TCP | FreeSWITCH, WebRTC over secure WebSocket | the node's address |
| `16384`–`32768` | UDP | **RTP — the audio itself** | the node's address |
| `4000` | TCP | node health and API | all interfaces |
| `9060` | UDP | SIP capture (HEP) collector | all interfaces |
| `8021` | TCP | FreeSWITCH ESL | `127.0.0.1` only |
| `8090` | TCP | Kamailio RPC | `127.0.0.1` only |

Two that surprise people: **the RTP range carries every call**, so a firewall
that passes SIP and blocks 16384–32768 gives calls that connect and have no
audio; and `4000` binds every interface, not just loopback, so restrict it if
the node sits on an untrusted network.

**Putting the node on the same machine as other VoIP software?** The node claims
that whole SIP set. Anything else already holding one of them wins the bind and
the node loses that leg silently — a FreeSWITCH profile that cannot bind its TLS
port does not start at all, so phones simply never register. Check before
installing:

```sh
ss -lntup | grep -E ':(5060|5061|5066|5070|5081|5090)\b'   # anything listed is a clash
```

The VoIPAppz mothership already accounts for this and keeps its own SIP ingress
on `5160`/`5161`, so a node and a mothership can share one machine.

Two files describe the node, and this repository ships an example of each:

| File | What it is |
|---|---|
| `/opt/voipappz/config/va.yaml` | the node: uuid, addresses, ports, gateways, mothership, broker — see [`va.yaml.example`](va.yaml.example) |
| `/opt/voipappz/.env` | written by the installer: the three generated secrets `docker run` passes in, and the image it runs |

The YAML is the only source. The container turns it into its own environment at
boot (`voipappz env --export`, the `va-env` step), which is how Kamailio learns
its addresses and FreeSWITCH its ports. Edit the YAML and restart; never edit
the `.env`.

## Operate it

The CLI ships inside the image — there is nothing to install on the host:

```sh
docker exec va-voip voipappz health          # every check, and what is down
docker exec -it va-voip voipappz monitor     # live monitor: health, counters, SIP capture
docker exec va-voip voipappz dump            # the config the node is running
docker exec va-voip voipappz sbc egress sync # apply config/va.yaml to Kamailio
docker exec va-voip voipappz node --help     # registration commands
docker exec va-voip voipappz --help          # everything else
```

`config/va.yaml` in `/opt/voipappz` is the node's configuration; `docker run`
mounts it at `/tmp/node.yaml`. Edit it, then `sbc egress sync` (or restart).

The same CLI also runs **from the host** if you put it there (see
[the `voipappz` CLI](#the-voipappz-cli)). On a node box it resolves the
installation on its own — `/opt/voipappz/config/va.yaml`, its `.env` and the
`va-voip` container — so there is no directory to stand in and nothing to
export:

```sh
voipappz health                        # the node's own verdict
voipappz sbc egress list               # what Kamailio is routing on
voipappz sbc egress sync               # apply config/va.yaml to Kamailio
voipappz test scenario call --to 1001  # a real SIPp call, aimed at this node
```

`INSTALL_DIR=…` points it at a node installed somewhere other than the default.
Starting and stopping the container is not the CLI's job. `sh install.sh
--start-only` starts the installed node with the installer's own `docker run`;
`make up` / `make down` do the same from a checkout when you name the
installation's two files:

```sh
sudo make up VA_ENV_FILE=/opt/voipappz/.env VA_CONFIG=/opt/voipappz/config/va.yaml
sudo make down
```

## Reinstall and upgrade

Re-running the installer is safe: it keeps an existing `va.yaml`, `.env` and CA
bundle, and registration is idempotent by node UUID.

```sh
# upgrade to one exact build from the GitHub registry (the safe way: you know what runs)
export VA_REGISTRY_USER='<github-user>' VA_REGISTRY_TOKEN='<token with read:packages>'
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_IMAGE_SOURCE=registry VA_VOIP_IMAGE=ghcr.io/voipappz/node:<YYYY.MM.DD-build> sh
unset VA_REGISTRY_TOKEN

# or the newest: VA_IMAGE_SOURCE=registry always pulls, so :latest is refreshed
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_IMAGE_SOURCE=registry sh

# or the latest published archive from S3
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_IMAGE_SOURCE=s3 sh

# or from a file you carried over (offline)
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_IMAGE_ARCHIVE=/path/va-crystal-node-latest.tar.gz sh
```

A registry or an archive you name is always fetched, replacing the present
image — that is how a node is upgraded. The image tags are listed in the
GitHub registry (`ghcr.io/voipappz/node`, private): `<YYYY.MM.DD>-<build>` per
build, `latest` the newest. The archives come from va-crystal's `make s3-archive` /
`make s3-publish`.

## Unattended

The installer takes no arguments; every setting is an environment variable —
or a line in a real `.env` file beside `install.sh` (or `VA_ENV_FILE=…`). Copy
[`.env.example`](.env.example), fill in the mothership and your Account
login, keep it mode 0600, and run `sh install.sh`: whatever the file answers
is not asked. Variables already in the environment win over the file.

```sh
export VA_REGISTRY_USER='<github-user>' VA_REGISTRY_TOKEN='<token with read:packages>'
export VA_API_AUTHORIZATION='Basic <account-key>'

curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_CONFIG=/absolute/path/va.yaml sh

unset VA_REGISTRY_TOKEN VA_API_AUTHORIZATION
```

| Variable | Meaning |
|---|---|
| `VA_CONFIG=/path/va.yaml` | Install this node YAML instead of answering the wizard. |
| `VA_API_URL=https://…` | Mothership URL; persisted to `va.yaml`. |
| `VA_API_AUTHORIZATION='Basic …'` | Account key, instead of the prompt. |
| `VA_NATS_TOKEN=…` | Mothership URL-safe NATS key. Uses the derived `/nats` endpoint without a second URL; kept out of YAML. |
| `VA_NATS_URL=https://…/nats` | Broker, when the YAML has none. May carry credentials (`https://default:token@host/nats`): they go to the mode-0600 `.env` and the container environment only — the YAML gets the bare URL. ALL secrets live in env, never in `va.yaml`. |
| `VA_CUSTOMER_UUID` / `VA_CUSTOMER_NAME` | Pick (or create) the customer. |
| `VA_ACCOUNT_EMAIL` / `VA_ACCOUNT_PASSWORD` | The login of the Account a *new* customer gets; asked when a customer is created. The installer signs in with it once to prove it works, then forgets the password. |
| `VA_IMAGE_SOURCE=registry\|s3\|archive\|local` | Image source without the menu. `registry` pulls `VA_VOIP_IMAGE` (always, so a moving tag is refreshed) with `VA_REGISTRY_USER` / `VA_REGISTRY_TOKEN`; `dockerhub` is its old name. `local` uses the image already on this host and never fetches. |
| `VA_REGISTRY_USER` / `VA_REGISTRY_TOKEN` | The registry login: for ghcr.io a GitHub user and a classic token with `read:packages`. The token goes to `docker login` on stdin, in a temporary config removed after the pull; it is never written to the installation. |
| `VA_IMAGE_ARCHIVE=<path or URL>` | The archive to load (`.tar`/`.tar.gz`). A URL **must** publish a sibling `.sha256`; a download that does not match it, or has none, is refused. |
| `VA_IMAGE_URL=https://…` | Override the S3 archive URL used by `s3`. |
| `VA_VOIP_IMAGE=<ref>` | Image to run (default `ghcr.io/voipappz/node:latest`; name an exact `<YYYY.MM.DD>-<build>` tag to pin a build). The old Docker Hub image `nirlevi/va-crystal:node` is still accepted. |
| `VA_KAMAILIO=off` | Install a node without its own kamailio — it relies on an external SBC (the mothership ingress). Topology, so it lives in the container environment (recorded in the install `.env`, passed with `docker -e`); health reports the kamailio checks as "off by config". |
| `VA_FREESWITCH=off` | Install a proxy/agent-only node without media. |
| `VA_ED137=1` | ED-137 (ATM voice) node: kamailio probes trunk peers every second and marks them down within 2 s, marks SIP DSCP CS5, and adds `WG67-Version` and `a=maxptime:30` on the answers to trunk peers. Recorded in the install `.env`, passed with `docker -e`. The node's `ed137` role sets the trunk codecs. |
| `VA_CA_BUNDLE=/path/chain.pem` | Trust anchors for a mothership whose chain the node cannot verify. |
| `INSTALL_DIR=/path` | Where the stack lands (default `/opt/voipappz`). |
| `START=0` | Install and register, do not start the container. |

Some of those are decisions, not settings, so they are also options:
`sh install.sh --no-register` installs and starts a node without touching a
mothership (register it later); `--no-start` is `START=0`; `--image-only`
gets the image, proves its CLI runs, and stops — prepare a machine once, then
install on it offline with `VA_IMAGE_SOURCE=local`; `--start-only` is the other
end of that pair — it starts the node already installed here and does nothing
else. Through the one-liner: `curl -fsSL … | sh -s -- --no-register`.

## No internet at all: the installer ISO

For a machine with no route out, there is a bootable disc. It carries Ubuntu
24.04, Docker Engine, the node image and this `install.sh`, and it installs the
*machine* — the operator then runs one command, which is this installer again,
loading the image off the local disk:

```console
$ va-node-install
```

That is `VA_IMAGE_SOURCE=archive` with `VA_IMAGE_ARCHIVE` pointing at the disc's
copy of the image; nothing about installation is reimplemented on the disc. The
image is offline, **registration is not** — that step still has to reach your
mothership, or run `va-node-install --no-register` and register later.

The disc is restricted media: it holds a private container image in the clear,
so it is distributed by presigned link and must not be re-hosted.
The disc is cut **here** (it moved from voipappz/mothership in 2026-09, where
it had always built node media):

```console
$ make iso-payload     # once — pull and save the node image
$ make iso             # cut the disc
$ make iso ISO_DEST=/mnt/d/isos
```

`packer/README.md` is the build's own account of itself, including the gotchas
that cost real time. `make iso-ship ISO_HOST=…` sends a cut disc to a machine;
`make iso-node-install ISO_HOST=…` installs onto one that already has it.

## What it guarantees

- **Nothing is written to `/opt/voipappz` until registration succeeded.** The
  stack, `va.yaml` and `.env` are staged in `/tmp` and copied in one step; a
  failed run leaves the machine as it was.
- **Credentials never land on disk.** The Docker token is used through a
  temporary Docker config and deleted; the Account key exists only in the
  registration process. Neither appears in YAML, `.env`, or the log.
- **Mothership TLS is pinned, not skipped.** A certificate that is not in the
  trust store is shown (subject, issuer, SHA-256) and its chain saved as
  `config/ca-bundle.pem`; the node then accepts that certificate and no other.
  A leaf served without its intermediate cannot be pinned — pass the CA with
  `VA_CA_BUNDLE`.
- **Customers are never moved.** One visible customer is used; several require
  `VA_CUSTOMER_UUID` or `VA_CUSTOMER_NAME`; a customer on another node, a
  disabled one, or an interrupted `Customer::Init` stops the install (the
  marker `.customer-provisioning-incomplete` says so).

## Troubleshooting

| Symptom | Do this |
|---|---|
| `va-voip did not pass node health` | `docker exec va-voip voipappz health` — it names each failing check |
| Container will not start | `docker logs va-voip` — the boot preflight names what is wrong in the YAML |
| Registration failed on TLS | pass the mothership's CA: `VA_CA_BUNDLE=/path/chain.pem` |
| Calls do not route | `docker exec va-voip voipappz sbc egress sync`, then `voipappz health` |
| Calls connect but there is **no audio** | the RTP range is blocked — open UDP `16384`–`32768` to the node |
| Phones never register, health shows a FreeSWITCH profile down | something else on the machine holds one of the node's SIP ports — see [Ports](#ports); `ss -lntup \| grep -E ':(5060\|5061\|5066\|5070\|5081\|5090)'` names it |
| Wrong mothership | rerun with `VA_API_URL=https://…` (it is persisted to `va.yaml`) |

## The `voipappz` CLI

The `voipappz` CLI is no longer built here (2026-10-29). Its source lives in
github.com/voipappz/node (`cli/`), which compiles it into the node image, so
every node runs the CLI of its own image: `docker exec va-voip voipappz …`.
`install.sh` only ever ran that copy, and still does.

Where a host copy is still wanted (the node disc bakes one), `make build`
copies the same binary out of the node image — no compiler, no release:

```sh
make build                                        # bin/voipappz from ghcr.io/voipappz/node:latest
make build NODE_IMAGE=ghcr.io/voipappz/node:<tag>  # ... or from a given image
```

The public `latest` and `v*` CLI releases this repo used to publish are no
longer updated.

## More

- [DEVELOPMENT.md](DEVELOPMENT.md) — changing the installer: `make check`,
  `make install`, `make test`, and how a change lands.
- CI runs on Ubuntu 22.04 and 24.04 on every push and pull request: unit tests,
  a clean-host install (Docker Hub, local archive, URL archive), registration
  and customer handling against a real mothership, the node's real-time limits
  and `make up` / `make down` against an installation, and the running node's
  health and SIP. The CLI job runs the spec suite, links the static binary, and
  drives a SIPp round trip.
- Contributing: `main` is protected. Open a pull request; it merges once all
  seven CI jobs are green. See DEVELOPMENT.md, "Landing a change".

### Broker transport

Normal node configuration uses one public origin:

```yaml
mothership:
  url: https://switch.voipappz.io
env: {}
```

The installer derives `https://switch.voipappz.io/nats`, preserving a custom
HTTPS port. Existing `broker.url` values are preserved; an explicit
`nats://internal-host:4222` override remains available for internal services
and tests. Public connections should use HTTPS/WSS through Kong.

Keep the NATS key in the protected environment, not YAML. Supply
`VA_NATS_TOKEN` with the mothership's URL-safe key to use the derived endpoint
without repeating the hostname.
`VA_NATS_URL` can carry `https://default:<key>@switch.voipappz.io/nats`;
the installer stores the credentialed form only in the mode-0600 environment
file and passes it to the node. A shared key authenticates a node but does
not isolate tenants or node subjects: use it only for trusted infrastructure.

`make test-nats-https` runs the published node process through the real
Mothership Kong and NATS configuration. CI runs it as `nats-https` on trusted
PRs, main pushes, and manual runs. It covers authenticated health request/reply,
JetStream initialization, reconnect, internal TCP, invalid/missing keys,
untrusted certificates, wrong TLS hostnames, and refusal of plaintext upgrades.
It uses the existing `MOTHERSHIP_TOKEN` and Docker Hub CI secrets. For local
`act` runs, mount a Mothership checkout and set `MOTHERSHIP_DIR`; set the
`NODE_TEST_IMAGE` act variable to select a cached node image. The separate
full-install job continues to cover SIP/media and registration.

The Mothership origin/auth hardening must land before this new CI job: it
requires `/nats` to reject unrelated browser origins. The changed CLI defaults
must also be released and included in node images before using YAML without a
broker override on an existing node.

The NATS and full-install jobs pin Mothership fixture `1d638d64a91f176020815095ed8f32d82d53b901`.
A manual workflow dispatch can override `mothership_ref`; update the reviewed
fixture pin when adopting later Mothership changes.
