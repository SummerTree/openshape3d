# Driving openshape3d from Claude

A DEBUG-only loopback HTTP channel that lets an external agent inspect and drive
the running app. Two clients ship with it, both speaking the same HTTP:

| Client | Integration | Why |
|---|---|---|
| **Claude Code** | `.claude/skills/drive-openshape3d/SKILL.md` | It has a shell, so `curl` is a complete client. No server process |
| **Claude Desktop** | `scripts/mcp_openshape3d.py` | It has no shell, so it needs a real MCP server |

The MCP server holds no logic of its own — every tool is a thin call to the
endpoints below — so the two clients cannot drift apart.

## Safety posture

- Entirely `#if DEBUG`. A Release build has neither the code nor the sandbox
  entitlement (`ENABLE_INCOMING_NETWORK_CONNECTIONS` is set on the Debug
  configuration only).
- Off unless `OS3D_AGENT` is set, like every other `OS3D_*` hook.
- Loopback only, enforced twice: the `NWListener` interface constraint, plus a
  peer check in `accept(_:)` that refuses any non-loopback address.
- No authentication, because there is no remote to authenticate. Do not add a
  LAN binding without also adding a token.

## Files

| File | Role |
|---|---|
| `openshape3d/Agent/AgentServer.swift` | The socket. `NWListener`, loopback enforcement, response writing |
| `openshape3d/Agent/AgentHTTP.swift` | Framing: incremental request parser, `Content-Length` bodies |
| `openshape3d/Agent/AgentRouter.swift` | Routing and every reply that needs no editor |
| `openshape3d/Agent/AgentBridge.swift` | The `@MainActor` hop; holds the live `EditorViewModel` weakly |

The split exists so the parts worth testing are testable. `AgentHTTPTests` and
`AgentRouterTests` cover framing and routing as pure values, with no sockets and
no `EditorViewModel` — which the unit suite cannot instantiate anyway, since an
in-process `ModelContainer` crashes XCTest (STATUS gotcha 1). What is left
untested is the socket and the hop, both of which are thin.

## Launching

### iOS Simulator

The simulator shares the Mac's network stack, so the app's loopback is yours —
nothing to forward.

```bash
SIMCTL_CHILD_OS3D_AGENT=1 SIMCTL_CHILD_OS3D_FRESH=1 \
  xcrun simctl launch 69DB84F4-607C-46F2-9089-3E8C0770B4A9 com.laan.labs.openshape3d
```

Do not use `--console-pty &` from an agent tool call: when the call ends its
process group dies, the pty closes, and the app goes with it. A plain
`simctl launch` survives. `/v1/state` is a better diagnostic than the console.

### Mac Catalyst

```bash
launchctl setenv OS3D_AGENT 1 && open /path/to/openshape3d.app && launchctl unsetenv OS3D_AGENT
```

Must go through LaunchServices. Exec'ing the binary directly gives no
entitlement context, `listen()` silently no-ops, and the listener still reports
`.ready`. Diagnostic: `lsof -nP -iTCP -a -p <pid>` shows `(CLOSED)`.

### Physical iPad

The device's loopback is not the Mac's. Forward over USB:

```bash
brew install libimobiledevice
iproxy 8787 8787 &
```

`usbmuxd` connects to `127.0.0.1` **on the device**, so the app's loopback-only
posture is preserved end to end. `xcrun devicectl` has no port-forward verb. Set
`OS3D_AGENT` in the scheme environment — there is no `SIMCTL_CHILD_` equivalent
for a device launch.

### Where this does not reach

The Claude iOS app cannot drive the app on the same iPad. It has no shell and no
arbitrary-HTTP tool, and its connectors are remote MCP over HTTPS, which cannot
address the device's own loopback. The only architecture that would work is an
outbound relay — the app dials a hosted server and a remote connector talks to
that — which means public hosting, OAuth, and model data leaving the device.
Deliberately not built. Drive a USB-connected iPad from the Mac instead.

## Protocol

`http://127.0.0.1:8787`, JSON unless stated. `OS3D_AGENT_PORT` overrides.
`protocol` in `/v1/health` is bumped on any incompatible response change.

### `GET /v1/health`

Answered on the listener queue without touching the main actor — a liveness
probe that blocks behind a wedged UI reports the one condition it exists to
detect as a timeout.

```json
{"ok":true,"protocol":1,"app":"openshape3d","port":8787,"pid":36567,
 "platform":"simulator","hasDocument":true}
```

### `GET /v1/commands`

Exactly what Command Search offers — the 37 commands that reach the editor, not
the wider ~60-entry catalog. An agent handed the full catalog wastes turns on
ids that cannot run.

```json
{"ok":true,"count":37,"commands":[{"id":"sketch.arc","title":"Arc","category":"sketch","chord":"A"}]}
```

### `GET /v1/state`

```json
{"ok":true,"document":"Untitled 2","mode":"editingPrimitive","platform":"simulator",
 "selection":["BB96E231-…"],"selectedSketchEntities":0,
 "bodies":[{"id":"BB96E231-…","name":"Box","hidden":false,"volumeMM3":64,"brep":false}],
 "sketchCount":0,"featureCount":0,"canUndo":true,"canRedo":false,"undoTitle":"Add Box",
 "measurements":[{"label":"Volume","value":"64.00 mm³"},{"label":"Bounds","value":"4.00 × 4.00 × 4.00 mm"}],
 "commandSearchActive":false}
```

`measurements` is the same array `SelectionInfoBar` renders, so an agent and a
person reading over its shoulder never disagree about what the model measures.
`brep` says whether a body is still analytic or has been flattened to its
tessellation — the distinction the OCCT port exists for.

Verify geometry here, not in a screenshot: an image cannot show that a boolean
produced a 0 mm³ body.

### `POST /v1/command`

Body `{"id":"view.isometric"}`. Returns the full state plus `ran`.

The one thing this endpoint exists to get right: `EditorViewModel.runCommand`
returns a single `Bool` for three different situations. A human pressing a dead
key presses another one; an agent told only "false" retries forever. So:

| Status | `error` / field | Meaning |
|---|---|---|
| 200 | `"ran": true` | Ran |
| 200 | `"ran": false`, `"reason":"not_applicable"` | Real id, wrong editor state. `message` names the mode and selection count |
| 400 | `unknown_command` | No such id |
| 400 | `unrouted_command` | In the catalog, no editor entry point in this build |
| 400 | `missing_id` | Body was absent or carried no `id` |
| 405 | `method_not_allowed` | Wrong verb |
| 409 | `no_document` | Gallery on screen; open a project |

The first two 400s are decided without ever reaching the main actor, because
`CommandRegistry.all` and `routableIDs` are pure statics.

### `GET /v1/screenshot?w=&h=`

PNG bytes, rendered by the app itself — so it works identically on Catalyst and
on a device, where `simctl io screenshot` does not exist. Sizes clamp to
64–4096, default 1024.

Sleep ~1s after any `view.*` command before capturing: standard views animate,
and an immediate capture catches the camera mid-flight, which looks exactly like
the command having failed.

## Registering the MCP server

Claude Desktop — `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{"mcpServers": {"openshape3d": {
  "command": "python3",
  "args": ["/Users/jclaan/projects/ios/openshape3d/scripts/mcp_openshape3d.py"]}}}
```

Claude Code picks the same server up from the project's `.mcp.json`, though the
skill and plain `curl` are the lighter path there.

Stdlib-only and Python 3.9-compatible on purpose: it runs inside Claude
Desktop's launch environment, not yours, where a missing dependency surfaces as
an unexplained failure.

## What this cannot do yet

`runCommand` **arms** tools; it does not parameterize them. `model.extrude` puts
the editor in extrude mode — the distance and the commit are separate
interactions with no endpoint. So an agent can navigate, inspect, seed, undo,
set views, and capture, but cannot yet say "extrude this profile to 12 mm".

Closing that means a `POST /v1/exec` with a small typed verb set
(`{"op":"extrude","distance":12}`, `{"op":"commit"}`) over VM methods that
already exist. It is the only remaining piece that needs new judgment about
which of ~200 `begin*`/`update*`/`commit*` methods to expose, which is why it is
not in this pass. Until then, finish parameterized operations by driving the
simulator UI and read the result over the bridge.
