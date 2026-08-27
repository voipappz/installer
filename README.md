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
    1) pull nirlevi/va-crystal:node from Docker Hub (needs a Docker Hub user + token)
    2) download the latest image archive from Amazon S3
    3) load a docker-save archive (.tar or .tar.gz) from a local path or URL
  Choose 1, 2 or 3 [2]: 2          ← Enter is enough
  downloading https://voipappz-assets-il.s3.il-central-1.amazonaws.com/images/…
  sha256 verified

3/6  Node stack
  installed the stack and verified its in-container CLI

4/6  va.yaml
  Node name [node-45d979c7-…]:     ← Enter, or type a name
  Available network interfaces:
    1. 10.0.0.10  eth0 (detected)
  Choose internal IP [1]:          ← Enter
  External IP [10.0.0.10]:         ← Enter, or the public address
  Mothership URL [https://cloud.voipappz.io]:   ← Enter, or your own
  broker derived from the mothership host: nats://cloud.voipappz.io:4222

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

Kamailio, FreeSWITCH and the node agent run together in it, on the host network:
SIP `5060` (Kamailio), `5070`/`5090` (FreeSWITCH phones/carriers),
health `127.0.0.1:4000`, Kamailio RPC `127.0.0.1:8090`, FreeSWITCH ESL
`127.0.0.1:8021`.

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

`config/va.yaml` in `/opt/voipappz` is the node's configuration; Compose mounts
it at `/tmp/node.yaml`. Edit it, then `sbc egress sync` (or restart).

## Reinstall and upgrade

Re-running the installer is safe: it keeps an existing `va.yaml`, `.env` and CA
bundle, and registration is idempotent by node UUID.

```sh
# upgrade to the latest published image
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_IMAGE_SOURCE=s3 sh

# or from a file you carried over (offline)
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_IMAGE_ARCHIVE=/path/va-crystal-node-latest.tar.gz sh
```

An archive you name is always loaded, replacing the present image — that is how
a node is upgraded. The archives come from va-crystal's `make s3-archive` /
`make s3-publish`.

## Unattended

The installer takes no arguments; every setting is an environment variable —
or a line in a real `.env` file beside `install.sh` (or `VA_ENV_FILE=…`). Copy
[`.env.example`](.env.example), fill in the mothership and your Account
login, keep it mode 0600, and run `sh install.sh`: whatever the file answers
is not asked. Variables already in the environment win over the file.

```sh
export VA_REGISTRY_USER='<docker-hub-user>' VA_REGISTRY_TOKEN='<docker-hub-token>'
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
| `VA_NATS_URL=nats://…` | Broker, when the YAML has none. |
| `VA_CUSTOMER_UUID` / `VA_CUSTOMER_NAME` | Pick (or create) the customer. |
| `VA_ACCOUNT_EMAIL` / `VA_ACCOUNT_PASSWORD` | The login of the Account a *new* customer gets; asked when a customer is created. The installer signs in with it once to prove it works, then forgets the password. |
| `VA_IMAGE_SOURCE=dockerhub\|s3\|archive` | Image source without the menu. |
| `VA_IMAGE_ARCHIVE=<path or URL>` | The archive to load (`.tar`/`.tar.gz`); a URL is checked against its `.sha256`. |
| `VA_IMAGE_URL=https://…` | Override the S3 archive URL used by `s3`. |
| `VA_VOIP_IMAGE=<ref>` | Image to run (default `nirlevi/va-crystal:node`). |
| `VA_CA_BUNDLE=/path/chain.pem` | Trust anchors for a mothership whose chain the node cannot verify. |
| `INSTALL_DIR=/path` | Where the stack lands (default `/opt/voipappz`). |
| `START=0` | Install and register, do not start the container. |
| `VA_REGISTER=0` | Install and start, do not register. |

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
mothership, or run with `VA_REGISTER=0` and register later.

The disc is restricted media: it holds a private container image in the clear,
so it is distributed by presigned link and must not be re-hosted.
See [packer/README.md](packer/README.md) to cut or publish one.

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
| Wrong mothership | rerun with `VA_API_URL=https://…` (it is persisted to `va.yaml`) |

## More

- [DEVELOPMENT.md](DEVELOPMENT.md) — changing the installer: `make check`,
  `make install`, `make test`.
- CI runs on Ubuntu 22.04 and 24.04 on every push: unit tests, a clean-host
  install (Docker Hub, local archive, URL archive), a full install driven
  through a real terminal, registration and customer handling against a real
  mothership, and the running node's health and SIP.
