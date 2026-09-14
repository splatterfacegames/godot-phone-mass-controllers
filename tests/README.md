# Tests

All GDScript tests run headless with Godot 4.7.1:

```sh
godot --headless --path . --import                              # once, builds the class cache
godot --headless --path . --script res://tests/run_tests.gd     # run every suite
godot --headless --path . --script res://tests/run_tests.gd -- --filter=http   # suites whose file name contains "http"
```

The exit code is `0` when every suite passes (skipped suites don't count as failures) and `1` otherwise.

## Writing a suite (the convention)

- Put the file in `tests/suites/` and name it `test_<area>.gd` (e.g. `test_qr_encode.gd`). The runner
  discovers every `test_*.gd` there, sorted by file name. Nothing needs registering.
- The script `extends RefCounted` (no `class_name`) and defines `func run(t) -> void`. `run` may be a
  coroutine (use `await`).
- `t` is a `PMCTestContext` (`tests/lib/test_context.gd`):

| member | what it does |
|---|---|
| `t.section(name)` | starts a named section; failures are reported as `suite > section: message` |
| `t.ok(cond, msg := "")` | passes when `cond` is truthy |
| `t.eq(actual, expected, msg := "")` | deep equality. Arrays and Dictionaries compare recursively, typed and untyped arrays compare by contents, and `int`/`float` compare numerically (JSON numbers are floats) |
| `t.near(actual, expected, eps := 1e-4, msg := "")` | numeric closeness |
| `t.fail(msg)` | records a failure |
| `t.skip(reason)` | marks the suite as skipped (e.g. an optional class is missing). Call it and then `return` |
| `t.note(msg)` | prints an informational line (always shown) |
| `await t.frame()` | waits one process frame |
| `await t.wait(seconds)` | waits wall-clock seconds while frames keep running |
| `await t.wait_until(cond: Callable, timeout := 5.0) -> bool` | pumps frames until `cond.call()` is truthy. Returns `false` on timeout (it doesn't fail by itself) |
| `t.add_node(node) -> Node` | adds a node under the root. It's freed automatically when the suite ends |
| `t.tree`, `t.root` | the `SceneTree` and its root `Window` |
| `t.tmp_dir() -> String` | an empty `user://pmc_tests/<suite>/` directory for scratch files |
| `t.class_available(name) -> bool` | whether a global `class_name` exists (use it to skip suites for optional classes) |

A suite passes when it records no failures **and** no GDScript runtime errors happen while it runs.
The runner installs a `Logger`, so a script error (null access, bad call, ...) fails the suite even
though GDScript would otherwise carry on. Engine warnings and non-script errors are ignored, because
robustness tests provoke them on purpose. Each suite gets a timeout of 120 s. Override it by declaring
`const TIMEOUT := <seconds>` in the suite.

Example:

```gdscript
extends RefCounted

func run(t) -> void:
	t.section("math")
	t.eq(1 + 1, 2)
	t.near(0.1 + 0.2, 0.3)
	t.section("async")
	var counter := [0]  # lambdas capture locals by value, so mutate a container instead of reassigning
	_tick_later(t, counter)
	t.ok(await t.wait_until(func(): return counter[0] > 0, 1.0), "counter ticked")

func _tick_later(t, counter: Array) -> void:
	await t.frame()
	counter[0] += 1
```

Helpers in `tests/lib/`:
- `PMCTestSocket`: a raw TCP client with HTTP response parsing (`http()`, `get_url()`).
- `PMCTestWs`: a masked WebSocket client (`open()`, `hello()`, `send_frame()`, `wait_json()`, `wait_close()`). It
  auto-answers pings unless `auto_pong = false`.
- `pmc_test_server.gd`: the headless echo host used by the Node tests.

## Node tests (`tests/node/`)

```sh
cd tests/node && npm ci
GODOT=/path/to/godot npm test         # ws-interop.test.mjs (node:test) and then qr-decode.mjs
GODOT=/path/to/godot npm run test:load
```

The Node tests spawn Godot headless as a child process. The WebSocket tests run `res://tests/lib/pmc_test_server.gd`,
an echo host that prints `PMC_READY port=<n>`. Set `GODOT` to the Godot executable if `godot` isn't on `PATH`.
`tests/node/.gdignore` stops the Godot editor from importing `node_modules`. `--script res://tests/node/qr-dump.gd`
still works, because `.gdignore` only affects the editor filesystem scan.

- `ws-interop.test.mjs` (25 tests): interop with the `ws` client (hello/welcome, text/binary echo, 1 MiB binary and
  text, client-side fragmentation with an interleaved ping, ping/pong both ways, heartbeat kill of a peer that
  doesn't pong, close-code echo, reject 4000, oversize 1009, abrupt terminate). Also raw-socket violations
  (unmasked, RSV bits, reserved opcodes, bad continuation, fragmented or oversized control frames, invalid UTF-8
  including across fragments, bad close codes and payloads, fragmented total over the max, a 2^63 length) and raw
  TCP garbage, partial headers and truncated frames.
- `qr-decode.mjs`: the QR encoder corpus, decoded by jsQR and ZXing and compared with `qrcode` (owned by the QR work).
- `load.test.mjs`: 200 concurrent clients (see below). Env: `CLIENTS`, `SECONDS`, `STAGGER_MS`, `BUDGET_MS`. It writes
  `tests/node/out/load.json` and exits 1 on message loss, or if the median frame exceeds 25 ms.

## Load / frame-time numbers

Setup: the headless Godot 4.7.1 host capped at 60 fps (`Engine.max_fps = 60`), with defaults `io_budget_msec = 8`
and `heartbeat_seconds = 15`. The host is polled once per frame, and `poll` is the time spent inside `PMCHost.poll()`
per frame (main thread). `frame` is the wall time between frames. The 200 Node `ws` clients run on the same machine
(Windows 11, Xeon W-2135, 6C/12T, loopback). They join 10 ms apart and send `{"t":"msg","d":{ts,pad(40 B)}}`, which
the host echoes back as JSON. "30 Hz broadcast" means the host also broadcasts a ~200-byte JSON state to all 200
clients 30 times a second.

| phase | msgs/s in | lost | echo RTT p50 / p99 (ms) | host poll avg / p99 / max (ms) | frame p50 / p99 / max (ms) |
|---|---|---|---|---|---|
| baseline: 1 idle client | 0 | 0 | – | 0.10 / 0.68 / 1.0 | 15.4 / 35.6 / 43.2 |
| 200 idle clients | 0 | 0 | – | 1.71 / 7.5 / 15.0 | 15.6 / 32.3 / 42.0 |
| 200 clients x 5 msg/s echo | 928 | 0 | 5.9 / 61.5 | 3.59 / 12.7 / 15.9 | 15.4 / 36.1 / 44.5 |
| 200 clients x 20 msg/s echo | 3450 | 0 | 15.0 / 107.8 | 7.41 / 13.6 / 21.1 | 15.5 / 36.6 / 45.7 |
| 200 x 20 msg/s + 30 Hz broadcast (200 B) | 3340 | 0 | 40.1 / 232.4 | 9.54 / 19.1 / 41.2 | 15.2 / 40.1 / 57.3 |
| 200 clients x 60 msg/s echo | 9545 | 0 | 69.2 / 197.5 | 9.90 / 17.7 / 28.7 | 15.3 / 38.9 / 40.6 |

What the numbers show:
- No messages were lost in any phase, and the median frame stayed at 60 fps. The frame p99 of about 35–40 ms shows
  up even with one idle client: it's Windows timer granularity in the `max_fps` sleep, not host work.
- Idle cost is about 8.5 µs per connected socket per frame (one `get_available_bytes` call, plus a staggered
  status check).
- Each echoed message costs about 40–50 µs of GDScript: frame decode ~20 µs, JSON parse and dispatch ~8 µs, and
  JSON encode and queue ~14 µs. On top of that come the socket syscalls. On this Windows machine each loopback
  `send`/`recv` took 30–80 µs (VPN/WFP filter drivers were installed), so expect lower numbers on Linux.
- Under heavy traffic, `io_budget_msec` trades latency for frame time. With a 4 ms budget, the 20 msg/s phase had
  about 108 ms RTT p50 and similar total CPU. With 12 ms it had about 11 ms RTT p50.
- The 1 MiB binary echo test peaks at about 4 ms of host poll time, because unmasking is spread over the frames in
  which the bytes arrive. Streaming a 5 MiB file peaks at about 9–18 ms, while the in-process test client is
  reading at the same time.
- 200 clients arriving 10 ms apart were all welcomed within about 6.6 s. With 30 ms spacing every client connected
  on schedule. Godot's `TCPServer` has a small fixed listen backlog, so connection bursts are retried by the OS.
