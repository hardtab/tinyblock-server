# Tiny Block Server

Headless dedicated server for **Tiny Block** — a Minecraft-style sandbox game built with Godot 4.

This repository contains the curated open-source dedicated server source code. It reuses the authoritative world simulation, multiplayer host, persistence, and backend signalling from the official Tiny Block client without including private store, analytics, advertising, or platform-specific code.

## Quick start

### Prerequisites

- Godot 4.7+ with Linux export templates installed.
- A Tiny Block backend API instance (default: the official public API).

### Build

```bash
# Export the server binary
godot --headless --export-debug "Dedicated Server (Linux/X11)" build/tinyblock-server.x86_64
```

### Run

```bash
./build/tinyblock-server.x86_64 \
  --tinyblock-server \
  --world my_first_world \
  --world-name "My Community Server" \
  --world-mode skyblock \
  --max-players 16
```

The server:
1. Authenticates as a guest installation.
2. Creates or loads the world identified by `--world`.
3. Publishes itself in the official server browser.
4. Accepts players using the official Tiny Block client.

### Arguments

| Argument | Default | Description |
|---|---|---|
| `--tinyblock-server` | — | Required. Enables headless server mode. |
| `--world <id>` | `world_community_1` | Stable world save identifier. Prefix with `world_` automatically if omitted. |
| `--world-name <name>` | `Tiny Block Community` | Public display name in the server browser. |
| `--world-mode <mode>` | `skyblock` | One of: `skyblock`, `floating_islands`, `procedural` (Random World), `one_block`, `challenge_run`. |
| `--max-players <1-16>` | `16` | Capacity advertised by this dedicated server. The backend validates and returns this value to clients. |

## Supported world modes

- **Skyblock** — classic skyblock: start on a small island with limited resources.
- **Floating Islands** — scattered floating islands in the sky.
- **Procedural** (Random World) — infinite procedurally generated terrain.
- **One Block** — a single regenerating block; mine it to progress.
- **Challenge Run** — pre-defined challenge scenarios.

## Multiplayer

The server reuses the official Tiny Block backend for:
- Guest authentication.
- Session creation and listing.
- WebSocket signaling.
- WebRTC data channel relay (with automatic fallback).

Active servers appear automatically in the **Online Worlds** list of the official client at `GET /v1/multiplayer/sessions`.

### Official vs Community

- **Official** — worlds operated by No Such Games (labelled in the client).
- **Community** — every other dedicated server.

Your server does not need pre-approval. It appears when its session is active and disappears after the session TTL expires. The server declares its own capacity with `--max-players`; ordinary player-hosted P2P worlds remain capped at 4.

## Persistence

World saves are stored under the Godot user data directory:

- Linux: `~/.local/share/godot/app_userdata/Tiny Block Server/`

Use `--world <id>` to keep the same world across restarts.

Progression, items, and world state stay on the server. The official Tiny Block servers do not store, back up, or synchronize community world saves.

## Project structure

```
tinyblock-server/
├── project.godot             # Godot project file
├── export_presets.cfg        # Linux dedicated server export
├── scenes/
│   └── server_main.tscn      # Server entry scene
├── scripts/
│   ├── server_main.gd        # Headless server entry point
│   ├── game_view.gd          # Authoritative simulation runner
│   ├── world.gd              # Authoritative world simulation
│   ├── world_store.gd        # World persistence
│   ├── block_defs.gd         # Block definitions
│   ├── biome_defs.gd         # Biome definitions
│   ├── backend_client.gd     # HTTP API client
│   ├── multiplayer_client.gd # WebSocket + WebRTC multiplayer
│   ├── art_assets.gd         # Block art definitions
│   ├── sfx.gd                # Simulation-compatible sound hooks
│   ├── emoji_reactions.gd    # Emoji validation
│   ├── player_profile.gd     # Player profile handling
│   ├── compact_number.gd     # Number formatting utility
│   └── analytics.gd          # Stub (no analytics)
├── assets/                   # Simulation audio and emoji assets
├── addons/
│   └── webrtc_native/        # WebRTC native plugin
├── tests/                    # Server and multiplayer tests
├── deploy/
│   ├── run-server.sh         # Example launch script
│   └── tinyblock-server.service.example  # Systemd unit example
├── README.md
├── SELF_HOSTING.md
├── CONTRIBUTING.md
├── SECURITY.md
├── THIRD_PARTY_NOTICES.md
└── LICENSE
```

## License

**AGPL-3.0-or-later** — see [LICENSE](./LICENSE).

The Tiny Block name and logos are not granted by the code license. Third-party components retain their original licenses (see [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)).
