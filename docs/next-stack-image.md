> **SUPERSEDED (2026-08-19). Read this for the reasoning, not the plan.**
>
> The two-image split below never shipped. `nirlevi/va-crystal:node` carries
> BOTH — `/usr/local/bin/voipappz` and `/stack` — so `install.sh` pulls one
> image, and there is no second cadence to keep in step and no version-skew
> rule to write. What survived intact is the `git archive HEAD` guard: the
> image's `/stack` is proven equal to it, which is what keeps the ISO and the
> image from drifting into two different payloads.

# Next: nirlevi/va-stack — the stack as an image

The last thing between `curl | sh` and a working install.

**TWO images, not one.** The first draft of this plan had a single `va-stack`
carrying both the stack and the CLI binary — and it could not be built here,
because the CLI is not here. It is in va-crystal. Building it would have meant
this repo reaching into another repo for an artifact at build time, which is the
exact coupling this whole migration removed.

So each repo builds an image out of what it already owns:

| image | built in | carries |
|---|---|---|
| `nirlevi/va-stack` | **here** | `/stack` — `git archive HEAD` (compose, config/, …) |
| `nirlevi/va-crystal:node` | **va-crystal** | `/usr/local/bin/voipappz` — it builds the CLI, so it ships it |

`install.sh` pulls both. That costs one extra pull and buys: no cross-repo build
dependency, each repo's CI able to publish its own image, and no question about
which repo is responsible when one of them is stale.

## What goes in

**`/stack` is `git archive HEAD` of this repo.** Not a `COPY .` — tracked files
only, which is the same decision `packer/build.sh:48` already made and for the
same reason: `data/`, `certs/`, `.env`, `config/va.yaml` and every other
host-generated path stay out **by construction** rather than by an ignore list
somebody has to maintain. A `COPY .` in a Dockerfile would bake one node's
secrets into an image pushed to a registry.

**The CLI is not in this image.** It comes from `nirlevi/va-crystal:node`, which is
built where the CLI source is. This repo has no binary to bake and should not
acquire one just to build an image.

## Shape

Small and boring on purpose:

```dockerfile
FROM alpine:3.20
COPY stack.tar.gz /tmp/
RUN mkdir -p /stack && tar -xzf /tmp/stack.tar.gz -C /stack && rm /tmp/stack.tar.gz
```

Roughly 12MB of stack on 7MB of alpine. It needs nothing this repo does not
have, which is the point.

**alpine rather than `scratch`**, though nothing is ever executed in it: the
image should be inspectable. `docker run --rm nirlevi/va-stack ls /stack` when
an install goes wrong is worth 7MB, and a `scratch` image gives you nothing to
look with.

**NOT `FROM nirlevi/va-crystal:node`.** Inheriting the node image would carry
FreeSWITCH, kamailio and the Crystal runtime — gigabytes — to deliver 12MB of
configuration, and would tie the stack's release cadence to the node's. The CLI
is **encapsulated in va-crystal's image**; this one stays a config payload and
knows nothing about it.

## Two artifacts must not disagree

The ISO already carries the stack, from `git archive HEAD` in
`packer/build.sh`. This adds a second way to obtain the same bytes, and two
paths to one payload is exactly how the `kamailio.cfg` drift happened.

So the guard is: **the image's `/stack` must equal `git archive HEAD`.**

```sh
docker create --name x nirlevi/va-stack:$TAG
docker cp x:/stack /tmp/from-image
git archive HEAD | tar -x -C /tmp/from-git
diff -r /tmp/from-image /tmp/from-git
```

Cheap, exact, and it fails the moment somebody adds a `COPY` that widens what
ships.

**Version skew is now the thing to watch.** The stack and the CLI ship as
separate images on separate cadences, so an install can pair a new stack with an
old binary. `install.sh` should pull both at the same tag where one exists, and
`voipappz` should say plainly when the stack it was handed is not the one it
knows — a mismatch nobody notices is a support call nobody can reproduce.

## Targets

```
make stack-image     build nirlevi/va-stack:<tag>   — needs nothing but this repo
make stack-verify    extract it and diff against git archive HEAD
make stack-publish   stack-verify, then docker push
```

No `make build` first, and no `VA_CRYSTAL_DIR`: the image is this repo's tracked
files and nothing else.

`stack-publish` **refuses a dirty tree**, same rule as the ISO and for the same
reason: an image published from uncommitted work cannot be traced to a commit,
and `latest` is not reproducible — CLAUDE.md already flags that about
`cli_version`. Tag with `git describe`; `:latest` moves as a convenience and is
never what an install should pin.

## What does NOT change

**The air-gapped path.** The ISO carries `docker save`d images and installs with
no registry at all. Nothing here may make the offline install depend on a login
it cannot perform — that is the entire premise of the installer ISO, and it is
the constraint most easily broken by accident while making the online path
simpler.

`stack_source=local` stays the default for bakes. This image serves the online
`curl | sh` install; the ISO keeps building its own tarball from the same
`git archive HEAD`, which is why the guard above matters.

## Order

1. **`make stack-image`** — build it locally, look inside it.
2. **`make stack-verify`** — prove `/stack` equals `git archive HEAD`. Nothing
   is published before this passes.
3. **`make stack-publish`** — push, with the dirty-tree refusal.
4. **Run the real thing**: `curl | sh` on a clean VM with only a token. That is
   the only test that counts, and it is the first time the whole chain —
   installer, registry, both images, stack, binary, bootstrap — runs end to end.
   It also depends on step 2 of the installer plan being done: without the CLI
   encapsulated in va-crystal's image there is nothing to extract.
5. **Delete what it replaces**: `release.yml`'s `voipappz-stack.tar.gz` asset,
   `bake.sh`'s `stack_source=release` branch, va-crystal's `cli-release.sh` and
   `cli-publish.sh`. Not before step 4 — a replacement is not a replacement
   until it has been seen working.

## Open

- **The node image must carry the CLI at `/usr/local/bin/voipappz`.** That is
  step 2 of docs/next-installer-endpoint.md and it is now a hard dependency of
  the installer, not a nice-to-have — `install.sh` extracts the binary from
  there.
- **Who builds and pushes?** Each repo builds its own, which is what makes CI
  possible at all: this repo's runner needs nothing from va-crystal to build
  va-stack. The earlier draft was manual-only precisely because it did.
- **Tag pairing.** Two images on two cadences need a rule for which pair is
  known-good. Simplest that works: `install.sh` defaults both to `:latest` and
  accepts an explicit tag for each, and something asserts the pair was tested
  together before it is called a release.
- **Retention.** Every tag is ~19MB in the registry forever. Worth a policy
  before there are two hundred of them.
