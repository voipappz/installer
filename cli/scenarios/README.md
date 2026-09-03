# SIPp scenarios

`voipappz test scenario` compiles a YAML manifest into a SIPp XML scenario plus
the RTP media it plays, then runs it.

```
voipappz test scenario                       # what is built in
voipappz test scenario call --to 1001        # a built-in, by name
voipappz test scenario ./my-scenario.yml     # or your own file
voipappz test scenario load --compile-only   # look before you run
voipappz test scenario load --dry-run        # print the sipp command
```

The manifests in this directory are compiled INTO the binary (`read_file`, see
`src/helpers/sipp/builtin.cr`). A provisioned host has the binary at
`/opt/cli/bin/voipappz` and the project at `/opt/va` — put there by different
steps — so an example that lived only as a repo file would be missing exactly
where a load test is worth running.

`test` is not registered in the `node_runtime` build, so the CLI baked into the
voip node image has no scenario command at all — this is a host-side tool.

With no `--destination`, a run goes to the address kamailio binds on port 5060 —
the same target `voipappz test` uses, honouring `VA_TEST_SIP_PORT`. Name the
extension onboarding created (`scripts/onboard-customer.sh` prints "SIP
extension A/B") with `--to`.

## What this is for

`voipappz test --level ping|invite|call|register` speaks SIP natively
(`src/helpers/sip.cr`) and is what the health path uses. It has no media and no
call rate: `--level heavy` spawns one sipexer process per call, so it cannot
hold N calls open, cannot pace a call rate, and cannot send a DTMF digit.

Scenarios cover the other axis:

| Need                                   | Use                                   |
| -------------------------------------- | ------------------------------------- |
| Is the proxy up? Does it route?         | `voipappz test --level ping\|invite`  |
| Does a whole dialog work?               | `voipappz test --level call`          |
| DTMF, IVR, real RTP                     | `test scenario dtmf`                  |
| Sustained call rate, concurrency, stats | `test scenario load`                  |
| Assert what the box PUT ON THE WIRE     | `test scenario trunk-offer-check`     |
| Watch live signalling on a real trunk   | `voipappz trace hep`                  |
| Anything over TLS or WSS                | sipexer — this SIPp build has no TLS  |

## Manifests

The compiler (`src/helpers/sipp/`) is a Crystal port of
[sippy_cup](https://github.com/mojolingo/sippy_cup) (MIT), so sippy_cup
manifests run here unchanged. Steps:

- `invite`, `register <user> [password]`
- `wait_for_call` (`receive_invite`), `send_trying`, `send_ringing`,
  `send_answer`, `answer`, `receive_ack`
- `receive_trying`, `receive_ringing`, `receive_progress`, `receive_answer`,
  `receive_ok`, `wait_for_answer`, `ack_answer`
- `sleep <seconds>`, `send_digits '<digits>'`, `receive_message ['<regexp>']`
- `send_bye`, `receive_bye`, `okay`, `wait_for_hangup`, `hangup`
- `assert_body '<regexp>'`, `assert_header '<Header:>' '<regexp>'`
- `call_length_repartition <min> <max> <interval>`,
  `response_time_repartition <min> <max> <interval>`

One departure from sippy_cup: `wait_for_answer` does NOT send the ACK. Its own
README documents the step as the receives alone, and ACKing there makes the
manifest in that same README ACK twice and play the media twice per call.

Transport is a manifest key: `transport_mode: t1` puts SIP over TCP (`tn` for a
socket per call). `ptime: 20` / `maxptime: 30` add those attributes to the SDP
this scenario offers.

## Asserting on what you receive

`assert_body` and `assert_header` attach a `check_it` regex to the message just
received, so a mismatch **fails the call** — it lands in SIPp's exit code and
failure counters. That is what makes a requirement like "every SDP offer to the
trunk carries `a=ptime:20` and `a=maxptime:30`" a CI check rather than something
someone re-confirms in Wireshark. See `trunk-offer-check.yml`.

A capture still earns its place for the first look at a live trunk — use
`voipappz trace hep`, which is already wired into both kamailios.

## Where SIPp comes from

An installed `sipp` on `PATH` wins. Otherwise the pinned release binary
(`v3.7.7`) is fetched once into `.cache/sipp` and sha256-verified, the same way
`scripts/test-ingress.sh` gets sipexer. It is statically linked and built with
pcap support, so there is nothing to compile and nothing to install.

That build has **no TLS** (`sipp -v` reports `v3.7.7-PCAP`). TLS and WSS testing
stays with sipexer.

Two of these scenarios meeting *with media* trips a segfault inside SIPp's own
pcap cleanup, after the dialog has completed (both 200s sent, BYE answered).
It is SIPp's bug, not the scenario's — the CLI reports it as
`SIPp was killed (AccessViolation)` rather than crashing. Point a media
scenario at a real system, or at `sipp -sn uas`, and it is fine.

Replaying media needs root — SIPp opens a raw socket for it — so the CLI adds
`sudo` when it is not already root.
