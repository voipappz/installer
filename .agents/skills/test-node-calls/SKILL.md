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

## 4. A SIP trunk — to a carrier, or between two PBXs

The trunk is defined in two places and nowhere else:

- **mothership**: a provider on the customer, `POST /api/providers name=… type=sip
  tariff_uuid=<the customer's Init tariff> profile[address]=<peer ip> profile[port]=5060
  profile[transport]=udp` (type `sip` is the only one the call path reads).
  Outbound needs a `POST /api/numbers number=… environment_uuid=…` matching a
  rate prefix of that tariff (Init gives `0`/`05`/`972`); inbound needs
  `POST /api/dids number=… type=dst bridge_type=extension bridge_uuid=<ext>
  environment_uuid=… provider_uuid=<provider>` (`number` is globally unique).
- **node**: `sip_interfaces[0].gateways: ['<peer ip>/32|<provider uuid>']` in
  `config/va.yaml`, then `voipappz sbc egress sync` → kamailio `address` grp 2,
  tag = provider uuid. Nothing pushes this automatically; the YAML is the source.

Outbound needs NOTHING else on the node: FS bridges to `sofia/gateway/SBC`,
kamailio asks the node `/sbc/outgoing`, the mothership picks the provider by
LCR from its own DB and answers the destination. No dispatcher row, no FS
gateway, no credentials on the node (IP trunks only; `register=true` gateways
are not generated).

Prove it with a fake peer on its OWN IP (a container on a bridge network,
`va-crystal:local` has sipp): outbound = 7100 dials the number, the peer runs
`sipp -sf /etc/sipp/uas-answer.xml -i <peer ip> -p 5060`; inbound = the peer runs
`sipp -sf /etc/sipp/call.xml -inf in.csv` with csv `<peer ip>;carrier;x;<did>`
against the node's 5060, 7099 waits as `uas-answer.xml`.

| Symptom | Cause | Fix |
|---|---|---|
| outbound: peer gets INVITE/200/ACK then immediate BYE; caller gets 480 `NORMAL_CLEARING` | peer answered PCMU to a PCMA offer (`sipp -sn uas` does) — bridge codec mismatch | answer PCMA (`uas-answer.xml`) |
| inbound: 503 within ~200 ms, node logs `refused (404): domain_not_found` | the app identifies the provider by the **From host**, not the source IP; a From host that is not the provider address finds nothing | csv domain = the provider's ip; properly, kamailio should name the admitting address row (`X-VA-Gateway`, branch `dev-kamailio-x-va-gateway`) |
| inbound: call connects, hangup gets `404 Not here` | peer's BYE carried no Route (`sipp -sn uac` ignores Record-Route) | use `call.xml`, which honours `[routes]` |
| every dialplan request hangs, `:4000` stops answering, `health` says NOT ANSWERING | node logged `NATS disconnected` and never recovered | `docker restart va-voip` (node bug: a dead broker should fail fast) |

### Two PBXs on one host, each the other's provider (proven 2026-08-30)

Nothing new is needed: each PBX is a plain `type=sip` provider of the other,
the caller's tariff prefix picks the trunk (LCR), and the call ENTERS the peer
as a public call that its DID maps to an extension. No dial prefix is cut, no
kamailio dialplan module, no change on the nodes beyond `gateways:`.

| | PBX A (`va-voip`, `.202`) | PBX B (`va-voip-b`, `.203`) |
|---|---|---|
| provider on the cloud | `trunk-to-lab-b` → `.203:5060` | `trunk-to-a` → `.202:5060` |
| own number (rate prefix `05`) | `0507000001` | `0508000001` |
| DID → extension | `0507000001` → 7099 (provider `trunk-to-lab-b`) | `0508000001` → 8001 (provider `trunk-to-a`) |
| `va.yaml gateways:` | `'.203/32\|<trunk-to-lab-b uuid>'` | `'.202/32\|<trunk-to-a uuid>'` |

Second node on the same host: give it its own IP (`ip addr add <ip>/32` — a
`/21` makes the kernel source LAN traffic from it and NAT breaks), and override
what the image hard-codes: kamailio cfg (`listen` on its IP, RPC `8092`, HEP
`9062`), `xml_curl.conf.xml` gateway-url → its node port (`4002`; the default
`localhost:4000` makes its FreeSWITCH load the OTHER node's profiles), node/FS
ports in `env:`. Its CLI then needs
`-e VA_NODE_PORT=4002 -e VA_FREESWITCH_PORT=8023 -e VA_KAMAILIO_RPC_URL=http://127.0.0.1:8092/RPC -e VA_KAMAILIO_TCP_PORT=8092`.

Call: 8001 registers on B and waits as `uas-answer.xml`; 7100 registers on A
and dials `0508000001` with `call.xml`. Pass = caller `Successful call | 1`,
A logs `200 POST /sbc/outgoing`, B logs `Dialplan request - dst:0508000001`
then `destination … 8001` and `answer`. Then the mirror (8002 → `0507000001`
→ 7099).

Known: the callee sees `caller_id_number: 0` — the originating rtjson has an
empty `effective_caller_id_number` (mothership side, where the rtjson is
built). A `Mothership timed out on crystal.request.dialplan.resolve` (2 s) is
the cloud path, not the trunk: retry.

## Do not

- Do not create extensions, subscribers or domains on the node by hand as the
  fix — they are mothership state; on-node changes are diagnostics only.
- Do not run `docker exec … printenv VA_*` to read the node's config; read
  `/run/s6/container_environment/<VAR>`.
- Do not test on the operator's live node when a `~/va-*` install dir or a VM
  from the installer ISO will do.
