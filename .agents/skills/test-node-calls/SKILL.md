---
name: test-node-calls
description: Prove a VA-Crystal node installed by this installer can register phones and carry calls against a mothership (cloud.voipappz.io or a local one) using the tools already inside the node image — sipp scenarios, the in-image voipappz CLI and its Crystal SIP client, and the mothership API. Use after an install, after re-pointing a node at another mothership, when a health check shows sofia 0/0 or a dispatcher with no target, or before claiming "calls work".
---

# Test node calls

Everything needed is inside the running node (`va-voip`): sipp 3.5.2 with the
va-crystal scenarios in `/etc/sipp/`, the `voipappz` CLI, `fs_cli`, `kamctl`.
Nothing is installed on the host. All commands below are `docker exec va-voip …`.

## 0. The node itself, before any SIP

```sh
docker exec va-voip voipappz health            # must be 16/16, sofia 2/2
# `health` already drives the CLI's OWN Crystal SIP client (cli/src/helpers/sip.cr —
# RFC 3261/2617 from the specs, no sipp): media_options_internal/external ARE its OPTIONS
# probes. `health --direct` is host-stack only and refuses inside the node.
docker exec va-voip voipappz sbc status        # dispatcher rows, domains, registrations
```

If `media_sofia_profiles: no profiles` / `sofia 0/0`: the eight per-leg keys
`ip_address_{internal,external}_{int,ext}_{sip,rtp}` in `config/va.yaml` are
stale. `Sofia.from_config` reads ONLY those — the coarse
`ip_address_internal/external` are not a fallback. Fix them, restart, then
`voipappz sbc sync` (reseeds the dispatcher from the YAML).

The FreeSWITCH password is not in `docker exec`'s environment (that is the
container's original env; the node's lives in s6):

```sh
docker exec va-voip sh -c 'fs_cli -p "$(cat /run/s6/container_environment/FREESWITCH_PASSWORD)" -x "sofia status"'
```

## 1. Extensions come from the mothership, via the API

Create them there, never on the node. The customer's Account (the one
`Customer::Init` created) sees only its own environment:

```sh
# list (usernames come back as user@domain; the stored username is bare)
curl -sS -K account.curl https://<mothership>/api/extensions
# create — environment_uuid and user_uuid are required (406 names what is missing)
curl -sS -K account.curl -X POST --data-urlencode username=7100 --data-urlencode name=test-7100 \
  --data-urlencode enabled=true --data-urlencode environment_uuid=<env> --data-urlencode user_uuid=<user> \
  https://<mothership>/api/extensions
# SIP password: PATCH, not PUT (PUT is 404). This is also what pushes the subscriber to the node.
curl -sS -K account.curl -X PATCH --data-urlencode password=<sip-pass> https://<mothership>/api/extensions/<uuid>
```

`account.curl` is a mode-0600 curl config holding `user = "email:password"` —
credentials never go on argv. Within seconds the subscriber appears:

```sh
docker exec va-voip voipappz sbc subscriber show     # 7100@<domain>
```

If it does not: the node is on the wrong broker. `broker.url` in va.yaml must
follow the mothership host; an existing value is preserved by the installer,
so a node re-pointed with `VA_API_URL` keeps its OLD broker until edited.

FreeSWITCH authenticates against the mothership's directory (xml_curl →
node:4000 → NATS), not kamailio's subscriber table, so `kamctl passwd` on the
node changes nothing for REGISTER. Prove the directory answers:

```sh
docker exec va-voip sh -c 'curl -sS -X POST -d section=directory -d action=sip_auth \
  -d sip_auth_username=7100 -d domain=<domain> -d key_value=<domain> http://localhost:4000/switch/config'
# expect ~1.1 KB of <user id="7100"> with an a1-hash = md5("7100:<domain>:<sip-pass>")
```

(`sip_auth_username`, not `user` — the router reads that key for `sip_auth`.)

## 2. REGISTER with sipp — the va-crystal argument form

`-inf` feeds the scenario; the digest credentials are `-au`/`-ap`. Without them
sipp authenticates as `service` and FreeSWITCH's 403 is correct.

```sh
docker exec va-voip sh -c 'cd /tmp && printf "SEQUENTIAL\n<domain>;7100;<sip-pass>\n" > reg1.csv &&
  sipp 127.0.0.1:5060 -sf /etc/sipp/register.xml -inf reg1.csv -m 1 -r 1 -timeout 20 \
       -au 7100 -ap <sip-pass> -nostdin'
# success: "Successful call | 0 | 1", exit 0.  Negative test: wrong -ap must exit 1.
docker exec va-voip sh -c 'fs_cli -p "$(cat /run/s6/container_environment/FREESWITCH_PASSWORD)" -x "show registrations"'
curl -sS -K account.curl https://<mothership>/api/extensions   # .registration is filled from the cloud side too
```

Also `/etc/sipp/options.xml` (needs any `-inf`; `[field0]` is the domain) and
`register-badpass.xml`.

## 3. A call between two extensions

The shape of `/etc/sipp/one-call.sh`: callee registers and waits as a UAS,
caller registers, caller INVITEs through kamailio 5060; the MOTHERSHIP's
dialplan routes it (`crystal.request.dialplan.resolve` over NATS — the only
per-call step processed by the Ruby API).

```sh
docker exec va-voip sh -c 'cd /tmp && BIND=<node internal ip>
printf "SEQUENTIAL\n<domain>;7099;<p99>\n" > reg99.csv
printf "SEQUENTIAL\n<domain>;7100;<p100>\n" > reg1.csv
printf "SEQUENTIAL\n<domain>;7100;<p100>;7099\n" > call.csv
sipp $BIND:5060 -i $BIND -sf /etc/sipp/register.xml -inf reg99.csv -m 1 -r 1 -timeout 20 -au 7099 -ap <p99> -p 5062 -nostdin
sipp -sf /etc/sipp/uas-answer.xml -nd -i $BIND -p 5062 -mp 6190 -m 1 -timeout 45 -nostdin >uas.log 2>&1 &
sipp $BIND:5060 -i $BIND -sf /etc/sipp/register.xml -inf reg1.csv  -m 1 -r 1 -timeout 20 -au 7100 -ap <p100> -p 5073 -nostdin
sipp $BIND:5060 -i $BIND -sf /etc/sipp/call.xml -inf call.csv -m 1 -r 1 -timeout 45 -au 7100 -ap <p100> -p 5073 -mp 6090 -nostdin'
# success: caller INVITE → 180 → 200 → ACK → BYE, "Successful call | 0 | 1"; -m 3 for three in a row
```

Read the failure from the node, not from sipp:

```sh
docker logs --since 2m va-voip 2>&1 | grep -aiE 'Dialplan|refused|DIALING|REGISTER' | grep -v amqp
```

| Node log says | Cause | Fix |
|---|---|---|
| `Mothership refused the dialplan (404): extension_not_found` for a caller that exists | several customers share one SIP domain and the API resolved by domain alone (`dialplan_resolve.rb`, `.first`) | API branch `fix/dialplan-resolve-by-node`; until deployed, give the test customer a unique domain: `PATCH /api/environments/<uuid> profile[domain]=…` |
| `domain_not_found` | the domain sent is not any enabled environment's `profile.domain` | check `GET /api/environments` |
| caller rings 30 s then hangs up, callee never sees INVITE | registration contact advertises `ip_address_external`; a NATed box cannot hairpin to its public IP | set `ip_address_external` to the reachable address for the test |
| `SECURITY: FS rejected REGISTER (403)` with no directory request logged | sipp ran without `-au/-ap` | add them |
| kamailio `sanity … request uri [sip:7099@$D]` | the CSV has a literal `$D` (quoting) | write the domain literally |
| REGISTER 401 then nothing | kamailio egress gates on its `domain` table — a defect (that check is the mothership INGRESS's job) | `voipappz sbc domain add --domain <domain>` as a workaround |

## 4. A call to a real number / from the PSTN

Needs a provider on the customer (`POST /api/providers`, `name` + `type` in
`sip did sms gateway …`), an outbound gateway, and for inbound a DID pointed at
the node's public 5060. Carrier credentials go in a 0600 file, not on argv or
in chat.

## Do not

- Do not create extensions, subscribers or domains on the node by hand as the
  fix — they are mothership state; on-node changes are diagnostics only.
- Do not run `docker exec … printenv VA_*` to read the node's config; read
  `/run/s6/container_environment/<VAR>`.
- Do not test on the operator's live node when a `~/va-*` install dir or a VM
  from the installer ISO will do.
