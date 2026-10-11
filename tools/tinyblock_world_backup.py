#!/usr/bin/env python3
"""Capture and verify Tiny Block community world checkpoints.

The capture command is intended to run on the host that owns the save files and
write a tar stream to stdout. Keep that stream encrypted in transit/storage.
Only the four primary JSON saves are read; backups, temporary files, bot state,
and credentials are deliberately outside this contract.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import secrets
import stat
import sys
import tarfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable


FORMAT_VERSION = 1
DEFAULT_ROOT_PREFIX = "/opt/tinyblock/fresh"
MAX_WORLD_BYTES = 128 * 1024 * 1024
OPEN_RETRIES = 8
OPEN_RETRY_SECONDS = 0.2
CHUNK_SIZE = 1024 * 1024


@dataclass(frozen=True)
class WorldSpec:
    label: str
    world_id: str
    mode: str
    relative_path: str

    @property
    def archive_path(self) -> str:
        return f"{self.world_id}.json"


WORLD_SPECS = (
    WorldSpec(
        "pandora",
        "world_pandora",
        "floating_islands",
        "home-fresh-floating-islands/.local/share/godot/app_userdata/Tiny Block Server/worlds/world_pandora.json",
    ),
    WorldSpec(
        "b612",
        "world_b612",
        "one_block",
        "home-fresh-one-block/.local/share/godot/app_userdata/Tiny Block Server/worlds/world_b612.json",
    ),
    WorldSpec(
        "wonderland",
        "world_wonderland",
        "procedural",
        "home-fresh-procedural/.local/share/godot/app_userdata/Tiny Block Server/worlds/world_wonderland.json",
    ),
    WorldSpec(
        "skyloft",
        "world_skyloft",
        "skyblock",
        "home-fresh-skyblock/.local/share/godot/app_userdata/Tiny Block Server/worlds/world_skyloft.json",
    ),
)


class BackupError(RuntimeError):
    """Raised when a checkpoint is unsafe or does not match its contract."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise BackupError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def _parse_json(raw: bytes, spec: WorldSpec) -> dict[str, object]:
    try:
        state = json.loads(raw, object_pairs_hook=_reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as exc:
        raise BackupError(f"{spec.world_id}: invalid JSON: {exc}") from exc
    if not isinstance(state, dict):
        raise BackupError(f"{spec.world_id}: world root must be an object")
    # bool is an int subclass in Python, so check the exact type.
    if type(state.get("schema_version")) is not int or state["schema_version"] != FORMAT_VERSION:
        raise BackupError(f"{spec.world_id}: unsupported save schema")
    if state.get("world_id") != spec.world_id:
        raise BackupError(f"{spec.world_id}: save has a different world_id")
    generation = state.get("generation")
    if not isinstance(generation, dict) or generation.get("mode") != spec.mode:
        raise BackupError(f"{spec.world_id}: save has a different world mode")
    required_types = {
        "tiles": list,
        "inventory": dict,
        "generated_definitions": list,
        "fluids": list,
        "tree_growth": list,
        "plant_growth": list,
    }
    for name, expected_type in required_types.items():
        if not isinstance(state.get(name), expected_type):
            raise BackupError(f"{spec.world_id}: invalid {name} field")
    return state


def _open_absolute_regular_no_follow(path: str) -> int:
    """Open an absolute path without following any symlink component."""
    if not os.path.isabs(path):
        raise BackupError("source path must be absolute")
    parts = Path(path).parts
    if len(parts) < 2 or any(part in ("", ".", "..") for part in parts[1:]):
        raise BackupError("source path contains an unsafe component")
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    directory_fd = os.open("/", directory_flags)
    try:
        for component in parts[1:-1]:
            next_fd = os.open(component, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        return os.open(parts[-1], file_flags, dir_fd=directory_fd)
    finally:
        os.close(directory_fd)


def _same_open_file_state(before: os.stat_result, after: os.stat_result, byte_count: int) -> bool:
    return (
        before.st_dev == after.st_dev
        and before.st_ino == after.st_ino
        and stat.S_ISREG(after.st_mode)
        and before.st_size == after.st_size == byte_count
        and before.st_mtime_ns == after.st_mtime_ns
    )


def capture_one(
    root_prefix: str,
    spec: WorldSpec,
    *,
    attempts: int = OPEN_RETRIES,
    retry_seconds: float = OPEN_RETRY_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
    after_open: Callable[[str, int], None] | None = None,
) -> tuple[bytes, dict[str, object]]:
    """Read one committed primary through a pinned descriptor.

    A concurrent atomic rename cannot redirect the open descriptor. If the
    primary is briefly absent between unlink and rename, retry only that open;
    never substitute `.tmp` or `.bak`.
    """
    source_path = os.path.join(root_prefix, spec.relative_path)
    started_at = _utc_now()
    started_ns = time.monotonic_ns()
    descriptor = -1
    for attempt in range(attempts):
        try:
            descriptor = _open_absolute_regular_no_follow(source_path)
            break
        except FileNotFoundError as exc:
            if attempt + 1 >= attempts:
                raise BackupError(f"{spec.world_id}: primary save stayed absent after bounded retries") from exc
            sleep(retry_seconds)
    if descriptor < 0:
        raise BackupError(f"{spec.world_id}: could not open primary save")

    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise BackupError(f"{spec.world_id}: primary save is not a regular file")
        if before.st_size <= 0 or before.st_size > MAX_WORLD_BYTES:
            raise BackupError(f"{spec.world_id}: primary save size is outside safe bounds")
        if after_open is not None:
            after_open(source_path, descriptor)
        chunks: list[bytes] = []
        byte_count = 0
        while True:
            chunk = os.read(descriptor, CHUNK_SIZE)
            if not chunk:
                break
            chunks.append(chunk)
            byte_count += len(chunk)
            if byte_count > MAX_WORLD_BYTES:
                raise BackupError(f"{spec.world_id}: primary save exceeded the size limit while reading")
        raw = b"".join(chunks)
        after = os.fstat(descriptor)
        if not _same_open_file_state(before, after, byte_count):
            raise BackupError(f"{spec.world_id}: opened primary changed while it was read")
    finally:
        os.close(descriptor)

    _parse_json(raw, spec)
    completed_at = _utc_now()
    record: dict[str, object] = {
        "world_id": spec.world_id,
        "mode": spec.mode,
        "archive_path": spec.archive_path,
        "source_relative_path": spec.relative_path,
        "source_device": before.st_dev,
        "source_inode": before.st_ino,
        "source_size_bytes": len(raw),
        "source_mtime_ns": before.st_mtime_ns,
        "source_ctime_ns": before.st_ctime_ns,
        "source_mtime_utc": datetime.fromtimestamp(before.st_mtime, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "capture_started_at_utc": started_at,
        "capture_completed_at_utc": completed_at,
        "read_duration_ms": round((time.monotonic_ns() - started_ns) / 1_000_000, 3),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "schema_version": FORMAT_VERSION,
        "checkpoint_semantics": "primary inode opened at capture start; independent per-world checkpoint",
    }
    return raw, record


def capture_payload(
    root_prefix: str = DEFAULT_ROOT_PREFIX,
    *,
    sleep: Callable[[float], None] = time.sleep,
    after_open: Callable[[str, int], None] | None = None,
) -> tuple[list[tuple[str, bytes]], dict[str, object]]:
    payload: list[tuple[str, bytes]] = []
    records: list[dict[str, object]] = []
    capture_started = _utc_now()
    for spec in WORLD_SPECS:
        raw, record = capture_one(root_prefix, spec, sleep=sleep, after_open=after_open)
        payload.append((spec.archive_path, raw))
        records.append(record)
    manifest: dict[str, object] = {
        "format": "tinyblock-community-world-checkpoint",
        "format_version": FORMAT_VERSION,
        "capture_id": secrets.token_hex(16),
        "capture_started_at_utc": capture_started,
        "capture_completed_at_utc": _utc_now(),
        "save_schema_version": FORMAT_VERSION,
        "world_count": len(records),
        "checkpoint_consistency": "four independent per-world checkpoints; not a single global instant",
        "source_selection": "primary JSON only; no .tmp or .bak fallback",
        "source_consistency": "pinned O_RDONLY|O_NOFOLLOW file descriptor; primary writes use temp then remove/rename replacement",
        "worlds": records,
    }
    payload.append(("manifest.json", (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode()))
    return payload, manifest


def _write_archive(payload: Iterable[tuple[str, bytes]], output: io.BufferedWriter) -> None:
    with tarfile.open(fileobj=output, mode="w|") as archive:
        for name, raw in payload:
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            info.mode = 0o600
            info.mtime = int(time.time())
            archive.addfile(info, io.BytesIO(raw))


def _allowed_archive_names() -> set[str]:
    return {spec.archive_path for spec in WORLD_SPECS} | {"manifest.json"}


def _read_exact_tar(archive_path: str) -> dict[str, bytes]:
    members: dict[str, bytes] = {}
    with tarfile.open(archive_path, mode="r:*") as archive:
        for member in archive.getmembers():
            if member.name not in _allowed_archive_names() or not member.isfile() or member.issym() or member.islnk():
                raise BackupError("archive contains an unexpected path or non-regular entry")
            if member.name in members:
                raise BackupError("archive contains a duplicate path")
            stream = archive.extractfile(member)
            if stream is None:
                raise BackupError("archive member could not be read")
            raw = stream.read(MAX_WORLD_BYTES + 1)
            if len(raw) != member.size or len(raw) > MAX_WORLD_BYTES:
                raise BackupError("archive member has an invalid size")
            members[member.name] = raw
    if set(members) != _allowed_archive_names():
        raise BackupError("archive does not contain exactly the expected four worlds and manifest")
    return members


def _read_file_no_follow(path: Path, limit: int) -> bytes:
    descriptor = _open_absolute_regular_no_follow(str(path))
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise BackupError(f"unsafe or oversized validation file: {path.name}")
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(descriptor, CHUNK_SIZE)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > limit:
                raise BackupError(f"validation file exceeded the size limit: {path.name}")
        raw = b"".join(chunks)
        if not _same_open_file_state(info, os.fstat(descriptor), len(raw)):
            raise BackupError(f"validation file changed while being read: {path.name}")
        return raw
    finally:
        os.close(descriptor)


def _hash_file_no_follow(path: Path) -> tuple[int, str]:
    descriptor = _open_absolute_regular_no_follow(str(path))
    digest = hashlib.sha256()
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise BackupError(f"encrypted artifact is not a regular file: {path.name}")
        size = 0
        while True:
            chunk = os.read(descriptor, CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
        after = os.fstat(descriptor)
        if not _same_open_file_state(before, after, size):
            raise BackupError("encrypted artifact changed while it was being hashed")
        return size, digest.hexdigest()
    finally:
        os.close(descriptor)


def verify_directory(
    directory: Path,
    godot_receipt_path: Path | None = None,
    encrypted_artifact_path: Path | None = None,
) -> dict[str, object]:
    manifest_raw = _read_file_no_follow(directory / "manifest.json", 4 * 1024 * 1024)
    try:
        manifest = json.loads(manifest_raw, object_pairs_hook=_reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BackupError(f"invalid checkpoint manifest: {exc}") from exc
    if not isinstance(manifest, dict) or manifest.get("format") != "tinyblock-community-world-checkpoint" or manifest.get("format_version") != FORMAT_VERSION:
        raise BackupError("unsupported checkpoint manifest")
    raw_records = manifest.get("worlds", [])
    if not isinstance(raw_records, list):
        raise BackupError("manifest worlds must be a list")
    record_map = {record.get("world_id"): record for record in raw_records if isinstance(record, dict)}
    if len(record_map) != len(raw_records) or set(record_map) != {spec.world_id for spec in WORLD_SPECS} or manifest.get("world_count") != len(WORLD_SPECS):
        raise BackupError("manifest does not name exactly the four contracted worlds")
    if manifest.get("checkpoint_consistency") != "four independent per-world checkpoints; not a single global instant":
        raise BackupError("manifest does not record independent checkpoint semantics")
    for spec in WORLD_SPECS:
        raw = _read_file_no_follow(directory / f"{spec.world_id}.json", MAX_WORLD_BYTES)
        state = _parse_json(raw, spec)
        record = record_map[spec.world_id]
        if (
            record.get("mode") != spec.mode
            or record.get("schema_version") != FORMAT_VERSION
            or record.get("archive_path") != spec.archive_path
            or record.get("source_relative_path") != spec.relative_path
            or record.get("sha256") != hashlib.sha256(raw).hexdigest()
            or record.get("source_size_bytes") != len(raw)
        ):
            raise BackupError(f"{spec.world_id}: saved bytes do not match the manifest")
        if int(state["schema_version"]) != FORMAT_VERSION:
            raise BackupError(f"{spec.world_id}: schema mismatch")

    godot_results: list[dict[str, object]] = []
    godot_result_map: dict[str, dict[str, object]] = {}
    godot_version: str | None = None
    if godot_receipt_path is not None:
        receipt_raw = _read_file_no_follow(godot_receipt_path, 1024 * 1024)
        try:
            receipt = json.loads(receipt_raw, object_pairs_hook=_reject_duplicate_keys)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise BackupError(f"invalid Godot restore receipt: {exc}") from exc
        if not isinstance(receipt, dict) or receipt.get("format") != "tinyblock-offline-restore-verification" or receipt.get("validator_version") != 1:
            raise BackupError("unsupported Godot restore receipt")
        godot_version = str(receipt.get("godot_version", "unknown"))
        raw_results = receipt.get("worlds", [])
        if not isinstance(raw_results, list):
            raise BackupError("Godot restore receipt worlds must be a list")
        godot_results = [result for result in raw_results if isinstance(result, dict)]
        godot_result_map = {str(result.get("world_id", "")): result for result in godot_results}
        if len(godot_results) != len(raw_results) or set(godot_result_map) != {spec.world_id for spec in WORLD_SPECS}:
            raise BackupError("Godot did not validate exactly the four contracted worlds")
        for spec in WORLD_SPECS:
            result = godot_result_map[spec.world_id]
            if result.get("mode") != spec.mode or result.get("deserialize_state_ok") is not True or int(result.get("schema_version", -1)) != FORMAT_VERSION:
                raise BackupError(f"Godot offline restore failed for {spec.world_id}")
            if result.get("sha256") != record_map[spec.world_id].get("sha256"):
                raise BackupError(f"Godot verified different checkpoint bytes for {spec.world_id}")
            if int(result.get("tile_count", 0)) <= 0:
                raise BackupError(f"Godot offline restore returned an empty world for {spec.world_id}")

    encrypted_artifact: dict[str, object] | None = None
    if encrypted_artifact_path is not None:
        artifact_size, artifact_sha256 = _hash_file_no_follow(encrypted_artifact_path)
        encrypted_artifact = {
            "file_name": encrypted_artifact_path.name,
            "size_bytes": artifact_size,
            "sha256": artifact_sha256,
            "encryption": "age",
        }

    return {
        "format": "tinyblock-world-backup-verification-receipt",
        "format_version": 1,
        "verified_at_utc": _utc_now(),
        "capture_id": manifest["capture_id"],
        "capture_started_at_utc": manifest["capture_started_at_utc"],
        "capture_completed_at_utc": manifest["capture_completed_at_utc"],
        "checkpoint_consistency": manifest["checkpoint_consistency"],
        "encrypted_artifact": encrypted_artifact,
        "worlds": [
            {
                "world_id": spec.world_id,
                "mode": spec.mode,
                "size_bytes": record_map[spec.world_id]["source_size_bytes"],
                "sha256": record_map[spec.world_id]["sha256"],
                "godot_offline_restore": bool(godot_results),
                "tile_count": int(godot_result_map[spec.world_id]["tile_count"]) if godot_results else None,
                "source_mtime_utc": record_map[spec.world_id]["source_mtime_utc"],
                "capture_started_at_utc": record_map[spec.world_id]["capture_started_at_utc"],
                "capture_completed_at_utc": record_map[spec.world_id]["capture_completed_at_utc"],
            }
            for spec in WORLD_SPECS
        ],
        "godot_version": godot_version,
        "restore_method": "WorldSim.deserialize_state in an isolated headless project; no server or multiplayer started",
    }


def extract_archive(archive_path: str, destination: Path) -> None:
    if destination.is_symlink() or not destination.is_dir() or any(destination.iterdir()):
        raise BackupError("extract destination must be an existing empty non-symlink directory")
    members = _read_exact_tar(archive_path)
    for name, raw in members.items():
        target = destination / name
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            view = memoryview(raw)
            while view:
                count = os.write(descriptor, view)
                view = view[count:]
        finally:
            os.close(descriptor)


def _command_capture(args: argparse.Namespace) -> int:
    if sys.stdout.isatty():
        raise BackupError("refusing to write a plaintext world archive to a terminal")
    payload, manifest = capture_payload(args.root_prefix)
    _write_archive(payload, sys.stdout.buffer)
    sys.stdout.buffer.flush()
    print(
        f"captured {manifest['world_count']} independent world checkpoints; archive bytes are on stdout",
        file=sys.stderr,
    )
    return 0


def _command_extract(args: argparse.Namespace) -> int:
    extract_archive(args.archive, Path(args.destination))
    print("archive extracted into private scratch; contents still require offline Godot validation")
    return 0


def _command_verify(args: argparse.Namespace) -> int:
    receipt = verify_directory(
        Path(args.directory),
        Path(args.godot_receipt) if args.godot_receipt else None,
        Path(args.artifact) if args.artifact else None,
    )
    encoded = (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode()
    if args.receipt_out:
        destination = Path(args.receipt_out)
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.write(descriptor, encoded)
        finally:
            os.close(descriptor)
    sys.stdout.buffer.write(encoded)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    capture = subparsers.add_parser("capture", help="emit encrypted-transport-ready tar to stdout")
    capture.add_argument("--root-prefix", default=DEFAULT_ROOT_PREFIX)
    capture.set_defaults(handler=_command_capture)
    extract = subparsers.add_parser("extract", help="safely extract an already decrypted archive")
    extract.add_argument("--archive", required=True)
    extract.add_argument("--destination", required=True)
    extract.set_defaults(handler=_command_extract)
    verify = subparsers.add_parser("verify", help="verify hashes/schema and optional Godot receipt")
    verify.add_argument("--directory", required=True)
    verify.add_argument("--godot-receipt")
    verify.add_argument("--artifact", help="optional encrypted archive to hash into the verification receipt")
    verify.add_argument("--receipt-out")
    verify.set_defaults(handler=_command_verify)
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except (BackupError, OSError, tarfile.TarError) as exc:
        print(f"backup error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
