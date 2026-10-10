from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tinyblock_world_backup as backup


def _state(spec: backup.WorldSpec, marker: str = "old") -> bytes:
    return json.dumps(
        {
            "schema_version": 1,
            "world_id": spec.world_id,
            "generation": {"mode": spec.mode},
            "tiles": [{"x": 1, "y": 2, "content_id": "core:stone", "marker": marker}],
            "inventory": {},
            "generated_definitions": [],
            "fluids": [],
            "tree_growth": [],
            "plant_growth": [],
        },
        separators=(",", ":"),
    ).encode()


class WorldBackupCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(dir="/private/tmp")
        # macOS exposes /tmp through /var, which is itself a symlink. The
        # production opener intentionally rejects symlink path components, so
        # give it the canonical physical temp-root path.
        self.root = Path(os.path.realpath(Path(self.temp.name) / "root"))
        self.root.mkdir()
        for spec in backup.WORLD_SPECS:
            source = self.root / spec.relative_path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(_state(spec))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_capture_pins_original_inode_across_primary_replacement(self) -> None:
        spec = backup.WORLD_SPECS[0]
        source = self.root / spec.relative_path
        replacement = source.with_name("replacement.json")
        replacement.write_bytes(_state(spec, "new"))
        swapped = False

        def replace_after_open(path: str, _descriptor: int) -> None:
            nonlocal swapped
            os.replace(replacement, path)
            swapped = True

        captured, record = backup.capture_one(
            str(self.root), spec, after_open=replace_after_open, sleep=lambda _seconds: None
        )
        self.assertTrue(swapped)
        self.assertEqual(json.loads(captured)["tiles"][0]["marker"], "old")
        self.assertEqual(json.loads(source.read_bytes())["tiles"][0]["marker"], "new")
        self.assertEqual(record["sha256"], hashlib.sha256(captured).hexdigest())

    def test_capture_never_falls_back_to_tmp_or_bak(self) -> None:
        spec = backup.WORLD_SPECS[0]
        source = self.root / spec.relative_path
        source.unlink()
        source.with_suffix(".json.tmp").write_bytes(_state(spec))
        source.with_suffix(".json.bak").write_bytes(_state(spec))
        sleeps: list[float] = []
        with self.assertRaisesRegex(backup.BackupError, "primary save stayed absent"):
            backup.capture_one(str(self.root), spec, attempts=3, retry_seconds=0.1, sleep=sleeps.append)
        self.assertEqual(sleeps, [0.1, 0.1])

    def test_missing_primary_retries_and_captures_when_rename_finishes(self) -> None:
        spec = backup.WORLD_SPECS[0]
        source = self.root / spec.relative_path
        source.unlink()
        attempts = 0

        def finish_rename(_seconds: float) -> None:
            nonlocal attempts
            attempts += 1
            if attempts == 2:
                source.write_bytes(_state(spec))

        captured, _record = backup.capture_one(
            str(self.root), spec, attempts=4, retry_seconds=0.01, sleep=finish_rename
        )
        self.assertEqual(json.loads(captured)["world_id"], spec.world_id)
        self.assertEqual(attempts, 2)

    def test_symlink_primary_is_rejected(self) -> None:
        spec = backup.WORLD_SPECS[0]
        source = self.root / spec.relative_path
        target = source.with_name("target.json")
        target.write_bytes(_state(spec))
        source.unlink()
        source.symlink_to(target)
        with self.assertRaises((OSError, backup.BackupError)):
            backup.capture_one(str(self.root), spec, sleep=lambda _seconds: None)

    def test_symlink_parent_is_rejected(self) -> None:
        spec = backup.WORLD_SPECS[0]
        home = self.root / "home-fresh-floating-islands"
        real_home = self.root / "real-home"
        home.rename(real_home)
        home.symlink_to(real_home, target_is_directory=True)
        with self.assertRaises((OSError, backup.BackupError)):
            backup.capture_one(str(self.root), spec, sleep=lambda _seconds: None)

    def test_schema_id_mode_and_duplicate_keys_fail_closed(self) -> None:
        spec = backup.WORLD_SPECS[0]
        source = self.root / spec.relative_path
        invalids = [
            b'{"schema_version":true}',
            json.dumps({"schema_version": 2, "world_id": spec.world_id, "generation": {"mode": spec.mode}}).encode(),
            json.dumps({"schema_version": 1, "world_id": "world_wrong", "generation": {"mode": spec.mode}}).encode(),
            json.dumps({"schema_version": 1, "world_id": spec.world_id, "generation": {"mode": "skyblock"}}).encode(),
            b'{"schema_version":1,"schema_version":1}',
        ]
        for raw in invalids:
            with self.subTest(raw=raw[:50]):
                source.write_bytes(raw)
                with self.assertRaises(backup.BackupError):
                    backup.capture_one(str(self.root), spec, sleep=lambda _seconds: None)

    def test_archive_contains_only_four_primary_worlds_and_manifest(self) -> None:
        payload, manifest = backup.capture_payload(str(self.root), sleep=lambda _seconds: None)
        self.assertEqual({name for name, _raw in payload}, backup._allowed_archive_names())
        self.assertEqual(manifest["world_count"], 4)
        self.assertEqual(manifest["checkpoint_consistency"], "four independent per-world checkpoints; not a single global instant")
        for name, raw in payload:
            if name.endswith(".json"):
                self.assertNotIn(b"achievement_state", raw)
                self.assertNotIn(b"backend_session", raw)

    def test_verify_requires_a_valid_godot_restore_receipt_when_requested(self) -> None:
        payload, _manifest = backup.capture_payload(str(self.root), sleep=lambda _seconds: None)
        directory = Path(self.temp.name) / "extracted"
        directory.mkdir(mode=0o700)
        archive_path = Path(self.temp.name) / "checkpoint.tar"
        with archive_path.open("wb") as archive_file:
            backup._write_archive(payload, archive_file)
        backup.extract_archive(str(archive_path), directory)
        receipt_path = Path(self.temp.name) / "godot.json"
        receipt_path.write_text(json.dumps({"format": "not-valid"}))
        with self.assertRaisesRegex(backup.BackupError, "unsupported Godot restore receipt"):
            backup.verify_directory(directory, receipt_path)

    def test_verify_accepts_exact_four_world_restore_receipt(self) -> None:
        payload, _manifest = backup.capture_payload(str(self.root), sleep=lambda _seconds: None)
        directory = Path(self.temp.name) / "valid-extracted"
        directory.mkdir(mode=0o700)
        archive_path = Path(self.temp.name) / "valid-checkpoint.tar"
        with archive_path.open("wb") as archive_file:
            backup._write_archive(payload, archive_file)
        backup.extract_archive(str(archive_path), directory)
        godot_receipt_path = Path(self.temp.name) / "valid-godot.json"
        godot_receipt_path.write_text(
            json.dumps(
                {
                    "format": "tinyblock-offline-restore-verification",
                    "validator_version": 1,
                    "godot_version": "test",
                    "worlds": [
                        {
                            "world_id": spec.world_id,
                            "mode": spec.mode,
                            "schema_version": 1,
                            "sha256": hashlib.sha256(_state(spec)).hexdigest(),
                            "deserialize_state_ok": True,
                            "tile_count": 1,
                        }
                        for spec in backup.WORLD_SPECS
                    ],
                }
            )
        )
        receipt = backup.verify_directory(directory, godot_receipt_path)
        self.assertEqual(len(receipt["worlds"]), 4)
        self.assertTrue(all(world["godot_offline_restore"] for world in receipt["worlds"]))
        self.assertEqual(receipt["godot_version"], "test")

    def test_verify_rejects_godot_receipt_for_different_checkpoint_bytes(self) -> None:
        payload, _manifest = backup.capture_payload(str(self.root), sleep=lambda _seconds: None)
        directory = Path(self.temp.name) / "mismatched-godot-extracted"
        directory.mkdir(mode=0o700)
        archive_path = Path(self.temp.name) / "mismatched-godot-checkpoint.tar"
        with archive_path.open("wb") as archive_file:
            backup._write_archive(payload, archive_file)
        backup.extract_archive(str(archive_path), directory)
        godot_receipt_path = Path(self.temp.name) / "mismatched-godot.json"
        godot_receipt_path.write_text(
            json.dumps(
                {
                    "format": "tinyblock-offline-restore-verification",
                    "validator_version": 1,
                    "godot_version": "test",
                    "worlds": [
                        {
                            "world_id": spec.world_id,
                            "mode": spec.mode,
                            "schema_version": 1,
                            "sha256": "0" * 64,
                            "deserialize_state_ok": True,
                            "tile_count": 1,
                        }
                        for spec in backup.WORLD_SPECS
                    ],
                }
            )
        )
        with self.assertRaisesRegex(backup.BackupError, "verified different checkpoint bytes"):
            backup.verify_directory(directory, godot_receipt_path)

    def test_verify_records_encrypted_artifact_hash_without_reading_plaintext(self) -> None:
        payload, _manifest = backup.capture_payload(str(self.root), sleep=lambda _seconds: None)
        directory = Path(self.temp.name) / "artifact-extracted"
        directory.mkdir(mode=0o700)
        archive_path = Path(self.temp.name) / "artifact-checkpoint.tar"
        with archive_path.open("wb") as archive_file:
            backup._write_archive(payload, archive_file)
        backup.extract_archive(str(archive_path), directory)
        encrypted_artifact = Path(self.temp.name) / "checkpoint.tar.age"
        cipher_bytes = b"opaque age ciphertext\x00\xff"
        encrypted_artifact.write_bytes(cipher_bytes)

        receipt = backup.verify_directory(directory, encrypted_artifact_path=encrypted_artifact)
        self.assertEqual(
            receipt["encrypted_artifact"],
            {
                "file_name": encrypted_artifact.name,
                "size_bytes": len(cipher_bytes),
                "sha256": hashlib.sha256(cipher_bytes).hexdigest(),
                "encryption": "age",
            },
        )
        manifest = json.loads((directory / "manifest.json").read_text())
        self.assertEqual(receipt["capture_started_at_utc"], manifest["capture_started_at_utc"])

    def test_verify_rejects_symlinked_encrypted_artifact(self) -> None:
        payload, _manifest = backup.capture_payload(str(self.root), sleep=lambda _seconds: None)
        directory = Path(self.temp.name) / "symlink-artifact-extracted"
        directory.mkdir(mode=0o700)
        archive_path = Path(self.temp.name) / "symlink-artifact-checkpoint.tar"
        with archive_path.open("wb") as archive_file:
            backup._write_archive(payload, archive_file)
        backup.extract_archive(str(archive_path), directory)
        target = Path(self.temp.name) / "target.age"
        target.write_bytes(b"ciphertext")
        artifact_link = Path(self.temp.name) / "linked.age"
        artifact_link.symlink_to(target)
        with self.assertRaises((OSError, backup.BackupError)):
            backup.verify_directory(directory, encrypted_artifact_path=artifact_link)


if __name__ == "__main__":
    unittest.main()
