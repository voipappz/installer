# VoIPAppz installer engineering notes

## Purpose

This is the public installer for one private VA-Crystal VoIP node. Keep the
installer small, POSIX-compatible, and driven by the existing `voipappz` CLI.
Do not reimplement CLI behavior in the installer.

The repositories have separate responsibilities:

- `installer` installs and registers a node and resolves its customer.
- `va-crystal` builds the private node image and the CLI bundled in it.
- `mothership` owns Accounts, customers, environments, and `Customer::Init`.

The installer must not modify VA-Crystal or install/start mothership. Mothership
is checked out and started only by the integration tests.

## Runtime contract

The default installation is `/opt/voipappz` and the default private image is
`nirlevi/va-crystal:node`.

`install.sh` performs this sequence:

1. Validate the requested installation directory and required inputs.
2. Install missing host tools and Docker Engine/Compose v2 on supported Ubuntu
   hosts.
3. Log in to Docker Hub with a temporary Docker configuration, pull the node
   image, and remove the temporary credentials.
4. Extract the existing `voipappz` binary and `/stack` from the image.
5. Install, preserve, or create `config/va.yaml` and ensure Compose mounts it
   at `/tmp/node.yaml`.
6. Register the node, resolve its customer, erase authorization from the
   process environment, and start only `voipappz up --profile voip`.

The installed node needs an external NATS broker. The installer may add
`mothership.url` or `broker.url` only when those values are absent from the
YAML. Existing YAML values win.

## Node registration contract

- `voipappz setup` creates or updates the node's `va.yaml`.
- `voipappz node register` reads that YAML and sends node data only.
- The installer passes Account Basic authorization in
  `VA_API_AUTHORIZATION` only for registration API operations.
- The mothership derives the Account and visible customers from that
  authorization.
- Node registration is idempotent by node UUID.
- Canonical node fields returned by the API may update `va.yaml` through the
  existing CLI behavior.
- The CLI never creates or posts a customer.
- Customer work begins only after node registration succeeds.

Do not move node parsing, validation, or node API payload construction into the
installer. That behavior belongs to the VA-Crystal CLI.

## Customer behavior

Customer resolution is deliberately handled by the installer against the real
mothership API:

- With one visible customer, use it.
- With multiple visible customers, require `VA_CUSTOMER_UUID` or the exact
  `VA_CUSTOMER_NAME`.
- Link an unassigned customer to the registered node.
- Treat a customer already linked to the same node as an idempotent success.
- Refuse to move a customer linked to another node.
- Refuse disabled, unknown, malformed, or ambiguous customer records.
- When an exact selected name does not exist, POST a new customer. The real
  mothership endpoint runs `Customer::Init` to create its environment and
  initial resources.

Before creating a customer, the installer writes the mode-0600
`.customer-provisioning-incomplete` marker. If the request result is unknown or
`Customer::Init` fails, keep the marker and stop. This prevents a blind retry
from duplicating partially initialized customer state. The marker contains only
the requested customer name, never a credential.

## Credential rules

These rules are non-negotiable:

- Never write `VA_API_AUTHORIZATION`, a Docker token, or an Account credential
  to YAML, `.env`, the installation directory, a container, or logs.
- Never pass a secret as a command-line argument when stdin or the process
  environment can be used.
- Prompt for secret values through `/dev/tty`, with terminal echo disabled.
- Use a private temporary Docker configuration for registry login and remove it
  on success, failure, or interruption.
- Unset registration authorization before starting the VoIP profile.
- Never commit real credentials or copy them into examples or tests.

The GitHub repository needs `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. The
token must be able to read the private `nirlevi/va-crystal` repository.

## CI design

`.github/workflows/ci.yml` tests Ubuntu 22.04 and 24.04.

The shell jobs verify executable bits, POSIX `sh`, `dash`, Bash test scripts,
ShellCheck, clean diffs, and the absence of Python production/test fakes.

The integration jobs run only for pushes and manual workflow dispatches because
fork pull requests cannot safely receive registry secrets. Each integration
job:

1. Checks out this public repository and public `voipappz/mothership`.
2. Runs `tests/clean-runner.sh` to remove the runner's preinstalled Docker
   packages.
3. Runs the public installer so Docker installation and the real private image
   pull are exercised on a clean host.
4. Uses the extracted CLI and mothership's committed `config/va.yaml.example`
   to boot the complete mothership `app + storage` environment with
   `voipappz up --profile app --wait --ci`.
5. Runs mothership's real onboarding script, Account authentication, node API,
   customer API, and `Customer::Init`.
6. Tests existing/new customer handling, exact-name idempotency, UUID
   idempotency, canonical node updates, ambiguous selection, unknown and
   disabled customers, re-home refusal, incomplete initialization, invalid
   authorization, and credential redaction.
7. Stops mothership, starts a separate NATS broker, starts the installed VoIP
   profile, and verifies node health and the `/tmp/node.yaml` bind mount.

There is no Python mock, fake API, or installer-specific customer model. Tests
must use the real public mothership and existing CLI.

`tests/clean-runner.sh` intentionally refuses to run outside GitHub Actions.
Do not weaken that guard because it purges Docker packages from its host.

## Verification

Run the fast checks before committing:

```sh
sh -n install.sh
dash -n install.sh
bash -n tests/clean-runner.sh tests/test-install.sh
shellcheck install.sh tests/clean-runner.sh tests/test-install.sh
git diff --check
```

The real integration test is driven by GitHub Actions. It requires the two
Docker Hub secrets and intentionally starts the complete mothership environment.

## Change discipline

- Prefer a direct shell fix over adding frameworks, generators, or new
  dependencies.
- Preserve existing `va.yaml` values and make reruns safe.
- Keep public documentation free of private implementation data and secrets.
- Update `README.md`, this file, and the real integration assertions whenever
  externally observable installer behavior changes.
- Do not claim the installer is fixed until both shell and integration jobs
  pass on Ubuntu 22.04 and 24.04.
