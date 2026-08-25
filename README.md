# VoIPAppz node installer

This public installer installs one private `va-crystal` VoIP node. The
mothership remains external; the installer starts only the `voip` profile.

## Install

On Ubuntu 22.04 or 24.04:

```sh
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh | sh
```

Run that command from any directory. There is no repository clone, `mise`,
Python, or manual dependency setup; the installer installs missing host
requirements itself and keeps the node in `/opt/voipappz`.

The installer prompts on the terminal for:

- The image source when the image is not already present: `1` pull from
  Docker Hub (user and access token), `2` download the latest published
  archive from Amazon S3 (default, no credentials), or `3` load a
  `docker save` archive (`.tar` or `.tar.gz`) from a local path or URL.
- The mothership URL (default `https://cloud.voipappz.io`), when neither
  `VA_API_URL` nor the YAML names one. The NATS broker is taken from the same
  host (`nats://<mothership-host>:4222`) unless the YAML or `VA_NATS_URL` says
  otherwise.
- The Account token (hidden input; the Account's Basic authorization key), or,
  when left empty, the Account email and password. The Basic value is built
  only in memory.
- Node setup answers when no `va.yaml` was supplied: node name, internal IP,
  external IP. Nothing about domains or certificates — those belong to the
  mothership's own setup.
- A customer name only when the Account has no customer yet.

For an unattended install, export the credentials and pass an existing YAML:

```sh
export VA_REGISTRY_USER='<docker-hub-user>'
export VA_REGISTRY_TOKEN='<docker-hub-token>'
export VA_API_AUTHORIZATION='Basic <account-credentials>'

curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_CONFIG=/absolute/path/to/va.yaml sh

unset VA_REGISTRY_TOKEN VA_API_AUTHORIZATION
```

To install and register against another mothership without starting the VoIP
containers:

```sh
VA_API_URL='https://mothership.example.com' \
VA_API_AUTHORIZATION='Basic <account-token>' \
START=0 sh -c 'curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh | sh'
```

An explicit `VA_API_URL` updates `va.yaml`, including on a rerun. The complete
Basic value exists only in the installer process; avoid putting a real token in
shell history on a shared machine.

Do not put the Account authorization in `va.yaml`. The default mothership is
`https://cloud.voipappz.io`; a `mothership.url` already present in the YAML
wins.

## Install from an image archive (offline, or without Docker Hub)

The node image can also be installed from a `docker save` archive
(`.tar` or `.tar.gz`) instead of being pulled from Docker Hub. No Docker Hub
user or token is asked for or used. The archive is produced by va-crystal's
`make s3-archive` (local file) or `make s3-publish` (uploaded to S3 as
`va-crystal-node-<VERSION>.tar.gz` and `va-crystal-node-latest.tar.gz`, each
with a `.sha256` beside it).

From a local file:

```sh
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_IMAGE_ARCHIVE=/absolute/path/va-crystal-node-2026.08.24-1.tar.gz sh
```

From a URL (downloaded to a temporary file, verified against the sibling
`.sha256` when one exists, removed after loading):

```sh
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh |
  env VA_IMAGE_ARCHIVE=https://<bucket-host>/images/va-crystal-node-latest.tar.gz sh
```

The installer takes no command-line arguments — it is piped into `sh`, so
every setting is an environment variable. It asks for `sudo` itself when the
install directory or Docker needs it. Interactively, run it with no variables
at all:

```sh
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh | sh
```

When `nirlevi/va-crystal:node` is not already in Docker it asks:

```
  Image source:
    1) pull nirlevi/va-crystal:node from Docker Hub (needs a Docker Hub user + token)
    2) download the latest image archive from Amazon S3
    3) load a docker-save archive (.tar or .tar.gz) from a local path or URL
  Choose 1, 2 or 3 [2]: 3
  Absolute path or http(s) URL of the image archive: /absolute/path/va-crystal-node-2026.08.24-1.tar.gz
```

Empty or invalid answers re-prompt. Unattended installs choose with
`VA_IMAGE_SOURCE=dockerhub|s3|archive` (or implicitly: `VA_IMAGE_ARCHIVE`
set → archive; registry variables set → Docker Hub) and never see the menu.
Option 2 downloads `VA_IMAGE_URL`, which defaults to
`https://voipappz-assets-il.s3.il-central-1.amazonaws.com/images/va-crystal-node-latest.tar.gz`
and is verified against its published `.sha256`.

Rules:

- `VA_IMAGE_ARCHIVE` must be an absolute path or an `http(s)` URL.
- If the image is already present in Docker, the archive is not used.
- The archive normally carries `nirlevi/va-crystal:node` and the pinned
  `node-<VERSION>` tag. If it was saved under another name, its single image is
  tagged as `VA_VOIP_IMAGE` (default `nirlevi/va-crystal:node`) so Compose
  finds it. An archive with several unrelated images is refused; set
  `VA_VOIP_IMAGE` to the one to use.
- The S3 objects are private by default; use a public-read policy on
  `images/*` or a pre-signed URL for URL installs.
- Everything after the image (stack extraction, `va.yaml`, registration,
  `docker compose --profile voip up -d`) is identical to a registry install.

## What it does

1. Installs Docker Engine and Compose v2 when Docker is absent.
2. Uses a temporary Docker configuration to pull
   `nirlevi/va-crystal:node`, then removes the registry credential file.
3. Extracts the bundled stack into `/opt/voipappz` and runs its existing CLI
   from the image.
4. Creates or updates `/opt/voipappz/config/va.yaml`; Compose mounts that file
   at `/tmp/node.yaml` in `va-voip`.
5. Runs `voipappz node register` in a temporary container. It reads the YAML
   and sends node data only.
6. Resolves the customer through the mothership API, starts only the `voip`
   profile with Docker Compose, and uses its CLI to apply the mounted YAML to
   Kamailio before waiting for node health.

The installer never starts or installs the mothership and never asks the CLI
to create a customer.

## Operate the node

The CLI lives in the node container. Use it for node operations:

```sh
cd /opt/voipappz
docker compose --profile voip ps
docker exec va-voip voipappz health
docker exec va-voip voipappz node --help
```

Docker Compose owns container lifecycle. The CLI owns node operations:
registration, configuration, Kamailio, FreeSWITCH, and health.

## Customer behavior

- One visible customer: use it.
- Several visible customers: set `VA_CUSTOMER_UUID` or `VA_CUSTOMER_NAME`.
- Existing selected customer: link it only when it is unassigned or already
  assigned to this node.
- Missing selected name: POST it through the mothership API. The real
  `Customer::Init` creates its Account, environment, and initial resources.
- Disabled customer or customer assigned to another node: stop without moving
  it.

Node registration is idempotent by node UUID. Customer creation is idempotent
by exact name. If customer creation is interrupted or `Customer::Init` fails,
the installer leaves `/opt/voipappz/.customer-provisioning-incomplete` and
refuses to claim success until an operator resolves the initialization and
removes that marker.

The Account Basic value is passed only in the registration process environment.
It is not written to YAML, `.env`, Docker, or installer logs.

## Useful controls

| Variable | Meaning |
|---|---|
| `VA_CONFIG=/path/va.yaml` | Install this node YAML. |
| `VA_IMAGE_ARCHIVE=/path/va-crystal.tar.gz` or `https://…/va-crystal-node-latest.tar.gz` | Load the node image from a `docker save` archive (local file or http(s) URL) instead of pulling it; no Docker Hub credentials are needed. A URL is downloaded to a temporary file, verified against a sibling `.sha256` when one is published, and removed after loading. If the archive was saved under another name, the single image it holds is tagged as `VA_VOIP_IMAGE`. |
| `VA_VOIP_IMAGE=<ref>` | Image reference to use (default `nirlevi/va-crystal:node`). |
| `VA_IMAGE_SOURCE=dockerhub\|s3\|archive` | Pick the image source unattended. `s3` downloads `VA_IMAGE_URL` (the latest published archive). |
| `VA_IMAGE_URL=https://…` | Override the S3 archive URL used by the `s3` source. |
| `INSTALL_DIR=/path` | Change the install directory. |
| `VA_CUSTOMER_UUID=<uuid>` | Select an existing visible customer. |
| `VA_CUSTOMER_NAME=<name>` | Select by exact name or create it. |
| `START=0` | Install and register without starting `va-voip`. |
| `VA_REGISTER=0` | Install/start without mothership registration. |
| `VA_API_URL=https://...` | Set the mothership URL and persist it to YAML. |
| `VA_NATS_URL=nats://...` | Add a broker URL when YAML has none (default: the mothership host, port 4222). |
| `VA_CA_BUNDLE=/path/chain.pem` | Extra PEM trust anchors for a mothership whose TLS chain the image cannot verify (for example, a server that omits its intermediate certificate). Copied to `config/ca-bundle.pem` and used by registration and customer API calls; TLS verification stays on. |

## CI coverage

GitHub Actions runs on Ubuntu 22.04 and 24.04. The integration job removes the
runner's preinstalled Docker packages, runs this installer, reinstalls from a
`docker save` archive without registry credentials, checks out the
public `voipappz/mothership`, and boots its complete `app + storage`
environment. It uses the real onboarding script, API, `Customer::Init`, and
node CLI to test existing/new customers, retries, conflicts, disabled records,
authorization failures, and UUID idempotency. It then shuts mothership down and
uses the in-container CLI to check the separate VoIP runtime, aggregate node
health, Kamailio, dispatcher routability, and the `/tmp/node.yaml` mount. There
is no Python or fake API in this repository.
