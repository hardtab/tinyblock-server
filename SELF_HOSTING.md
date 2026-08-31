# Self-hosting guide

This guide explains how to operate a Tiny Block dedicated server on your own machine or cloud host.

## Requirements

- Linux x86_64 (other platforms not yet tested)
- Outbound HTTPS access to the Tiny Block backend API
- WebSocket connectivity for signaling
- Persistent storage for world saves

## Installation

### From a release archive

1. Download the latest `tinyblock-server-linux-x86_64.tar.gz` from the [Releases](https://github.com/hardtab/tinyblock-server/releases) page.
2. Verify the checksum:

```bash
sha256sum -c tinyblock-server-linux-x86_64.tar.gz.sha256
```

3. Extract:

```bash
tar xzf tinyblock-server-linux-x86_64.tar.gz
cd tinyblock-server
```

### Building from source

```bash
git clone https://github.com/hardtab/tinyblock-server.git
cd tinyblock-server
godot --headless --export-release "Dedicated Server (Linux/X11)" build/tinyblock-server.x86_64
```

## Running

### Quick start

```bash
./build/tinyblock-server.x86_64 \
  --tinyblock-server \
  --world my_world \
  --world-name "My Server" \
  --world-mode skyblock \
  --max-players 16
```

### Background with systemd

1. Edit `deploy/tinyblock-server.service.example` to match your paths and arguments.
2. Copy the unit file:

```bash
sudo cp deploy/tinyblock-server.service.example /etc/systemd/system/tinyblock-server.service
sudo systemctl daemon-reload
sudo systemctl enable --now tinyblock-server
```

Logs: `journalctl -u tinyblock-server -f`

### Multiple worlds

Run separate processes with different `--world` and `--world-name` values:

```bash
# World 1: Skyblock
./tinyblock-server.x86_64 --tinyblock-server --world world_skyblock_1 --world-name "Skyloft" --world-mode skyblock

# World 2: One Block
./tinyblock-server.x86_64 --tinyblock-server --world world_oneblock_1 --world-name "B-612" --world-mode one_block
```

## Data directory

World saves are stored at:

| Platform | Path |
|---|---|
| Linux | `~/.local/share/godot/app_userdata/Tiny Block Server/` |

### Back up your worlds

```bash
tar czf tinyblock-backup-$(date +%Y%m%d).tar.gz ~/.local/share/godot/app_userdata/Tiny\ Block\ Server/
```

### Restore a world

1. Stop the server.
2. Copy the saved world file matching the `--world` ID into the data directory.
3. Restart the server.

## Update

1. Download the new release archive.
2. Stop the server.
3. Replace the server binary.
4. Restart the server.

Your world saves remain intact in the data directory.

## Configuration reference

| Argument | Type | Default | Description |
|---|---|---|---|
| `--tinyblock-server` | flag | — | Required. Run in headless server mode. |
| `--world` | string | `world_community_1` | Save file identifier. Prepended with `world_` if missing. |
| `--world-name` | string | `Tiny Block Community` | Public name in the server browser (max 64 chars). |
| `--world-mode` | string | `skyblock` | See supported modes below. |
| `--max-players` | integer | `16` | Server-declared capacity from 1 through 16. P2P worlds are unaffected and stay capped at 4. |

### Supported world modes

| Value | Description |
|---|---|
| `skyblock` | Classic skyblock: small island, limited resources. |
| `floating_islands` | Scattered floating islands. |
| `procedural` | Randomly generated world. |
| `one_block` | Single regenerating block. |
| `challenge_run` | Pre-defined challenges. |

## Visibility

- A server becomes visible in the official client **within seconds** of connecting to the signaling server.
- It stays visible while the heartbeat keeps its session alive (default ~45s after disconnect).
- To remove a server from the list, stop the process.

## Troubleshooting

### Server doesn't appear in the list

1. Check the server logs: does it print "connected to signaling"?
2. Verify outbound internet: the server needs HTTPS to `api.tinyblock.game` and WebSocket access.
3. Wait a few seconds after the "connected" message.
4. Check the backend is reachable: the server prints authentication errors explicitly.

### World doesn't load

- The `--world` value must not exceed 64 characters.
- If no saved world exists, a new one is created automatically.
- Corrupted saves may prevent loading; delete the save file and restart.

### Ports

The server initiates outbound connections only. No inbound ports are required. Multiplayer traffic uses WebRTC, which connects through STUN and may use ephemeral UDP ports.
