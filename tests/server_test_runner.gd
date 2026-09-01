extends Node

const WorldSim = preload("res://gameplay/scripts/world.gd")
const WorldStoreClass = preload("res://gameplay/scripts/world_store.gd")
const MultiplayerClientClass = preload("res://gameplay/scripts/multiplayer_client.gd")

var failures := 0
var test_dir := "user://tinyblock-server-tests"


func _ready() -> void:
	_test_all_modes_roundtrip()
	_test_persistent_store()
	_test_dedicated_roster_contract()
	_cleanup()
	if failures == 0:
		print("PASS: all five modes boot and round-trip, persistence reloads, dedicated host stays hidden")
	get_tree().quit(failures)


func _test_all_modes_roundtrip() -> void:
	var modes := [
		WorldSim.WORLD_MODE_SKYBLOCK,
		WorldSim.WORLD_MODE_FLOATING_ISLANDS,
		WorldSim.WORLD_MODE_PROCEDURAL,
		WorldSim.WORLD_MODE_ONE_BLOCK,
		WorldSim.WORLD_MODE_CHALLENGE,
	]
	for mode: String in modes:
		var sim := WorldSim.new()
		_generate(sim, mode)
		sim.world_id = "world_test_%s" % mode
		var state := sim.serialize_state()
		var restored := WorldSim.new()
		_assert(restored.deserialize_state(state), "%s state deserializes" % mode)
		_assert(restored.world_mode == mode, "%s keeps its mode" % mode)
		_assert(not restored.tiles.is_empty(), "%s contains world tiles" % mode)


func _test_persistent_store() -> void:
	var sim := WorldSim.new()
	sim.create_island()
	sim.world_id = "world_persistence_test"
	var store := WorldStoreClass.new(test_dir)
	_assert(store.save_world(sim.serialize_state()), "world save succeeds")
	var loaded := store.load_world(sim.world_id)
	_assert(bool(loaded.get("ok", false)), "world reload succeeds")
	var restored := WorldSim.new()
	_assert(restored.deserialize_state(loaded.get("state", {})), "reloaded state is compatible")
	_assert(restored.world_id == sim.world_id, "reloaded state preserves stable world id")


func _test_dedicated_roster_contract() -> void:
	var client := MultiplayerClientClass.new()
	client.set_session_max_players(7)
	client.set_dedicated_server_session(true)
	client.set_session_classification("community")
	client._handle_connected({
		"role": "host",
		"player_id": "headless-host",
		"session_id": "server-test",
		"players": [{"player_id": "headless-host", "role": "host"}],
	})
	_assert(client.max_players() == 7, "dedicated capacity comes from the server session")
	client.set_session_max_players(1000)
	_assert(client.max_players() == 1000, "dedicated capacity is not capped by the client runtime")
	_assert(client.player_count() == 0, "headless host is excluded from player count")
	_assert(client.is_community(), "third-party dedicated session is community")
	client.free()


func _generate(sim: RefCounted, mode: String) -> void:
	match mode:
		WorldSim.WORLD_MODE_FLOATING_ISLANDS:
			sim.create_floating_islands_world(101)
		WorldSim.WORLD_MODE_PROCEDURAL:
			sim.create_procedural_world(102)
		WorldSim.WORLD_MODE_ONE_BLOCK:
			sim.create_one_block_world(103)
		WorldSim.WORLD_MODE_CHALLENGE:
			sim.create_challenge_world(104)
		_:
			sim.create_island()


func _assert(condition: bool, label: String) -> void:
	if condition:
		return
	failures += 1
	push_error("FAIL: %s" % label)


func _cleanup() -> void:
	var absolute := ProjectSettings.globalize_path(test_dir)
	if DirAccess.dir_exists_absolute(absolute):
		for file_name in DirAccess.get_files_at(absolute):
			DirAccess.remove_absolute(absolute.path_join(file_name))
		DirAccess.remove_absolute(absolute)
