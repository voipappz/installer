# VoIPAppz node installer

This public installer installs one private `va-crystal` VoIP node. The
mothership remains external; the installer starts only the `voip` profile.

## Install

On Ubuntu 22.04 or 24.04:

```sh
curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh | sh
```

The installer prompts on the terminal for:

- Docker Hub user and access token, when the private image must be pulled.
- An Account Basic authorization value for mothership registration.
- Node setup answers when no `va.yaml` was supplied.
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

Do not put the Account authorization in `va.yaml`. The default mothership is
`https://cloud.voipappz.io`; a `mothership.url` already present in the YAML
wins.

## What it does

1. Installs Docker Engine and Compose v2 when Docker is absent.
2. Uses a temporary Docker configuration to pull
   `nirlevi/va-crystal:node`, then removes the registry credential file.
3. Extracts the existing `voipappz` CLI and bundled stack into
   `/opt/voipappz`.
4. Creates or updates `/opt/voipappz/config/va.yaml` and verifies Compose
   mounts it at `/tmp/node.yaml` in `va-voip`.
5. Runs the existing `voipappz node register` command. That command reads the
   YAML and sends node data only.
6. Resolves the customer through the mothership API, then starts only
   `voipappz up --profile voip` and waits for node health.

The installer never starts or installs the mothership and never asks the CLI
to create a customer.

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
| `INSTALL_DIR=/path` | Change the install directory. |
| `VA_CUSTOMER_UUID=<uuid>` | Select an existing visible customer. |
| `VA_CUSTOMER_NAME=<name>` | Select by exact name or create it. |
| `START=0` | Install and register without starting `va-voip`. |
| `VA_REGISTER=0` | Install/start without mothership registration. |
| `VA_API_URL=https://...` | Add a mothership URL when YAML has none. |
| `VA_NATS_URL=nats://...` | Add a broker URL when YAML has none. |

## CI coverage

GitHub Actions runs on Ubuntu 22.04 and 24.04. The integration job removes the
runner's preinstalled Docker packages, runs this installer, checks out the
public `voipappz/mothership`, and boots its complete `app + storage`
environment. It uses the real onboarding script, API, `Customer::Init`, and
node CLI to test existing/new customers, retries, conflicts, disabled records,
authorization failures, and UUID idempotency. It then shuts mothership down and
checks the separate VoIP runtime and `/tmp/node.yaml` mount. There is no Python
or fake API in this repository.
