# Tiny Block community world backups

## Scope

The dedicated Bare Metal host has four fresh public community worlds. Their
primary save files are independent JSON documents:

| World | ID | Mode | Host save path below `/opt/tinyblock/fresh/` |
|---|---|---|---|
| Pandora | `world_pandora` | `floating_islands` | `home-fresh-floating-islands/.local/share/godot/app_userdata/Tiny Block Server/worlds/world_pandora.json` |
| B-612 | `world_b612` | `one_block` | `home-fresh-one-block/.local/share/godot/app_userdata/Tiny Block Server/worlds/world_b612.json` |
| Wonderland | `world_wonderland` | `procedural` | `home-fresh-procedural/.local/share/godot/app_userdata/Tiny Block Server/worlds/world_wonderland.json` |
| Skyloft | `world_skyloft` | `skyblock` | `home-fresh-skyblock/.local/share/godot/app_userdata/Tiny Block Server/worlds/world_skyloft.json` |

This contract covers only those four primary world saves. It intentionally does
not include the Tiny Block bot's achievement/structural state, Godot session
files, tokens, or any product database. Bot files can be rewritten in place and
need their own backup contract. Never include `backend_session.json` in a world
archive.

## Consistency and freshness

`WorldStore.save_world` and `save_repaired_world` serialize to `<world>.json.tmp`,
flush and close that file, then publish a new primary by removing and renaming
files. Normal saves also rotate `.bak` by deleting the previous backup and
copying the primary. The backup copy is not a safe source during that rotation.
There are no other in-repository writers to these world primary paths.

The capture tool opens each exact primary using `O_RDONLY|O_NOFOLLOW`, pins the
opened inode, verifies it is a regular file, reads from that descriptor, checks
the descriptor metadata again, and validates JSON schema version, exact ID, and
mode before emitting any archive bytes. Linux keeps the opened inode readable
after the server unlinks/replaces the pathname. If the brief remove-to-rename
gap makes open return `ENOENT`, the tool retries a bounded number of times; it
never reads `.tmp` or silently substitutes `.bak`. Symlinks, non-regular files,
duplicate JSON keys, corrupt JSON, changed-in-place descriptor size/mtime, and
mismatched world metadata fail the whole capture. `ctime` is recorded but is
not compared because the producer's unlink-before-rename changes the old
inode's ctime even though its already-open contents remain stable.

Each world is a separate checkpoint taken at its own open time. The four saves
are **not** one globally atomic snapshot, and the manifest records per-world
capture start/completion times and SHA-256. During normal operation, the game
server autosaves dirty worlds with a configured maximum interval of 60 seconds
for ordinary worlds and 120 seconds for worlds at or above 50,000 tiles (with
an idle delay as well). Therefore a capture represents the most recently
published primary observed for each world; it can omit recent unsaved play,
normally bounded by that autosave maximum. This is an operational expectation,
not a hard durability SLA: the current Godot save path flushes the temp file but
does not explicitly fsync the file and containing directory.

## Capture and encryption

Run `tools/tinyblock_world_backup.py capture` on the host that owns the save
paths, and stream its tar output directly through the existing `age` recipient
to a private local artifact. Do not create a plaintext tar on disk or pipe its
contents to a terminal. Example from a Mac that has the already-authorized SSH
alias and protected age recipient file:

```sh
set -o pipefail
artifact_dir="$HOME/.config/hardtab/recovery/tinyblock-worlds"
mkdir -p "$artifact_dir"
chmod 700 "$artifact_dir"
partial="$artifact_dir/tinyblock-worlds-$(date -u +%Y%m%dT%H%M%SZ).tar.age.part"
final="${partial%.part}"
if ssh production-baremetal 'python3 - capture' \
    < tools/tinyblock_world_backup.py \
    | age -R "$HOME/.config/hardtab/recovery/sc-sp-20261010/recipient.txt" -o "$partial"; then
  chmod 600 "$partial"
  mv "$partial" "$final"
else
  rm -f "$partial"
  exit 1
fi
```

The script prints only a file-count summary to stderr. The stdout tar stream is
encrypted by `age`; the archive contains four primary files and a manifest with
IDs, modes, file metadata, independent capture timestamps, and hashes. Protect
the age identity as a private credential; never place it in the repository or
the archive. The protected Mac recovery folder is off-host relative to Bare
Metal, so this copy survives loss of the game host. A second cloud copy through
the existing approved Yandex recovery workflow, plus a recurring schedule and
retention policy, are still pending. That workflow's credentials are available
only to GitHub Actions; do not copy them to a Mac or create a new bucket/key.

For a durable verification record, run `verify` after extracting and restoring
the capture. Pass `--artifact` with the encrypted `.age` file; the private JSON
receipt then records the capture ID and time window, each world's source time
and hash, the offline restore result, and the encrypted artifact's filename,
size, and SHA-256. Keep the receipt beside the ciphertext; it contains metadata
only, not world contents or keys.

## Offline restore verification

Do not restore over a running world. Decrypt only into a new mode-0700 scratch
directory, validate the archive allowlist and hashes, then run the dedicated
Godot headless verifier against those copied JSON files. The verifier calls the
real `WorldSim.deserialize_state` for all four worlds, checks the restored ID,
mode, non-empty tile set, and SHA-256 of the exact input bytes; the Python
verifier rejects a Godot receipt whose hashes do not match the archive
manifest. It does not instantiate `ServerMain`, start multiplayer, or call the
backend client. Use a fresh isolated `HOME`/Godot user data directory. Keep the
resulting verification receipt beside the encrypted artifact; delete the
plaintext extraction scratch after validation.

Restore evidence proves the saved documents can be deserialized by this exact
Tiny Block source revision in isolation. It does not prove live community
joinability or backend health. Before a real restore/cutover, validate backup
age, source/target IDs and modes, hashes, and a complete restore test, then use
the normal reviewed production release/runbook to switch a world.

## Local tests

```sh
python3 -m unittest discover -s tools/tests -v
godot --headless --path . --scene res://tests/server_test_runner.tscn
```

Capture-contract tests cover inode pinning across replacement, bounded retry in
the unlink/rename gap, rejection of symlinks and temp/backup fallbacks, schema/
ID/mode validation, and the exact archive allowlist. Synthetic fixtures test
the capture implementation only; they are not evidence that the current four
world saves restore. The separate offline Godot receipt must be generated from
the actual decrypted production capture for that claim.
