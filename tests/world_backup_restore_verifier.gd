extends Node

const WorldSim = preload("res://gameplay/scripts/world.gd")
const EXPECTED_WORLDS := {
	"world_pandora": "floating_islands",
	"world_b612": "one_block",
	"world_wonderland": "procedural",
	"world_skyloft": "skyblock",
}


func _ready() -> void:
	_run_verification()


func _run_verification() -> void:
	var arguments := OS.get_cmdline_user_args()
	var world_directory := _argument_value(arguments, "--world-dir")
	var receipt_path := _argument_value(arguments, "--receipt")
	if world_directory.is_empty() or receipt_path.is_empty():
		push_error("Usage: -- --world-dir=<private scratch worlds directory> --receipt=<private scratch receipt path>")
		get_tree().quit(2)
		return

	var results: Array[Dictionary] = []
	var failed := false
	for world_id: String in EXPECTED_WORLDS:
		var path := world_directory.path_join("%s.json" % world_id)
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			push_error("Unable to open offline checkpoint for %s" % world_id)
			failed = true
			continue
		var parsed := JSON.new()
		var parse_error := parsed.parse(file.get_as_text())
		file.close()
		if parse_error != OK or not parsed.data is Dictionary:
			push_error("Invalid JSON checkpoint for %s" % world_id)
			failed = true
			continue
		var state: Dictionary = parsed.data
		var generation: Dictionary = state.get("generation", {}) if state.get("generation", {}) is Dictionary else {}
		if int(state.get("schema_version", -1)) != 1:
			push_error("Unsupported save schema for %s" % world_id)
			failed = true
			continue
		if str(state.get("world_id", "")) != world_id:
			push_error("World ID mismatch for %s" % world_id)
			failed = true
			continue
		var expected_mode: String = EXPECTED_WORLDS[world_id]
		if str(generation.get("mode", "")) != expected_mode:
			push_error("World mode mismatch for %s" % world_id)
			failed = true
			continue

		# Only construct the simulation and deserialize saved state. This harness
		# never creates ServerMain, starts multiplayer, or calls BackendClient.
		var simulation = WorldSim.new()
		var restored: bool = simulation.deserialize_state(state)
		var tile_count := int(simulation.tiles.size()) if restored else 0
		var restored_id := str(simulation.world_id) if restored else ""
		var restored_mode := str(simulation.world_mode) if restored else ""
		if not restored or restored_id != world_id or restored_mode != expected_mode or tile_count <= 0:
			push_error("WorldSim.deserialize_state did not restore %s from this checkpoint" % world_id)
			failed = true
			continue
		results.append({
			"world_id": world_id,
			"mode": expected_mode,
			"schema_version": 1,
			"sha256": FileAccess.get_sha256(path),
			"deserialize_state_ok": true,
			"tile_count": tile_count,
		})
		print("OFFLINE_WORLD_RESTORE_OK id=%s mode=%s tiles=%d" % [world_id, expected_mode, tile_count])

	if failed or results.size() != EXPECTED_WORLDS.size():
		get_tree().quit(1)
		return
	var receipt := {
		"format": "tinyblock-offline-restore-verification",
		"validator_version": 1,
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"verified_at_unix": Time.get_unix_time_from_system(),
		"network_calls_requested": 0,
		"server_started": false,
		"worlds": results,
	}
	var receipt_file := FileAccess.open(receipt_path, FileAccess.WRITE)
	if receipt_file == null:
		push_error("Unable to write private offline restore receipt")
		get_tree().quit(2)
		return
	receipt_file.store_string(JSON.stringify(receipt, "\t"))
	receipt_file.flush()
	receipt_file.close()
	get_tree().quit(0)


func _argument_value(arguments: PackedStringArray, name: String) -> String:
	for argument: String in arguments:
		if argument.begins_with("%s=" % name):
			return argument.trim_prefix("%s=" % name)
	return ""
