# Performance

How the host spends frame time, what the measured limits are, and the knobs that move them.

## Where the time goes

By default everything runs on the main thread inside `PMCHost.poll()`, once per frame, capped by
`io_budget_msec` (default 8 ms). Per connected socket per frame the host does roughly:

- one `get_available_bytes` — about 8.5 µs idle, plus a `poll()` status check staggered to every 15th frame;
- per echoed message about 40–50 µs of GDScript (frame decode ~20 µs, JSON parse + dispatch ~8 µs,
  JSON encode + queue ~14 µs), plus the socket syscalls — 30–80 µs per `send`/`recv` on Windows with
  filter drivers installed (expect less on Linux).

## Measured numbers

Headless Godot 4.7.1 on Windows 11 / Xeon W-2135, host at 60 fps, loopback, 200 Node `ws` clients joining
10 ms apart and sending `{"t":"msg","d":{...}}` which the host echoes. Full table and method:
[tests/README.md](../tests/README.md#load--frame-time-numbers).

| phase | msgs/s in | lost | echo RTT p50 / p99 | host poll avg / p99 |
|---|---|---|---|---|
| 200 idle clients | 0 | 0 | – | 1.71 / 7.5 ms |
| 200 × 20 msg/s echo | 3,450 | 0 | 15.0 / 107.8 ms | 7.41 / 13.6 ms |
| 200 × 60 msg/s echo | 9,545 | 0 | 69.2 / 197.5 ms | 9.90 / 17.7 ms |
| + 30 Hz broadcast (200 B) | 3,340 | 0 | 40.1 / 232.4 ms | 9.54 / 19.1 ms |

No messages were lost in any phase and the median frame stayed at 60 fps.

## `io_thread_enabled` — move socket I/O off the main thread

```gdscript
host.io_thread_enabled = true   # before start()
host.start()
```

A worker thread then owns accept, `read`/`write`, and HTTP/WS frame decode. The main thread drains a queue
of complete events — accepted sockets, parsed HTTP requests, decoded WS frames — inside `poll()`, applies
them, and queues outbound frames back through a per-connection lock. Game code, signals, `send()`,
`broadcast()`, routes and timers are unchanged and stay on the main thread.

- `io_budget_msec` still applies: it bounds how long `poll()` spends draining the event queue per frame.
  Undrained events keep their per-connection order and are handled next frame.
- Cross-thread handoff adds a little latency to ping/pong and write flushes (one worker pass, ~1 ms when
  idle) in exchange for taking the syscalls and frame decoding off the frame budget.
- Set it before `start()`; toggling while running does nothing. Per-player `rtt_ms` still works (the
  samples include the worker hop, so they read a few ms higher under load).
- Worker limits are snapshots taken at `start()`: `max_header_bytes`, `max_body_bytes`,
  `max_message_bytes`. Per-connection output (`send`, `broadcast`, responses) is mutexed; everything else
  on a connection is single-owner.

## Known limits either way

- **Burst joins are bounded by the OS, not the budget.** Godot's `TCPServer` listen backlog is small and
  not settable from GDScript. 200 clients connecting 10 ms apart took ~6.6 s to all get welcomed; with
  30 ms spacing every client connected on schedule. The OS retries refused connections, so this is slow,
  not broken. The io thread accepts up to 64 sockets per pass and helps drain bursts faster, but the
  backlog limit remains.
- **Big payloads hurt in one place: JSON.** Parsing costs ~60 ms per MiB and UTF-8 validation ~9 ms per
  MiB, all in one frame in main-thread mode. Prefer binary frames for large data (`message_received`
  delivers `PackedByteArray`), or parse off-thread in your game.
- `max_backlog_bytes` (16 MiB) drops sockets that can't keep up; `io_budget_msec` trades latency for
  frame time under load (a 4 ms budget roughly doubled echo RTT at 20 msg/s; 12 ms roughly halved it).
