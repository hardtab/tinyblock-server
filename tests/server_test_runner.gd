extends Node

const WorldSim = preload("res://gameplay/scripts/world.gd")
const WorldStoreClass = preload("res://gameplay/scripts/world_store.gd")
const MultiplayerClientClass = preload("res://gameplay/scripts/multiplayer_client.gd")
const ServerMainClass = preload("res://scripts/server_main.gd")

var failures := 0
var test_dir := "user://tinyblock-server-tests"


func _ready() -> void:
	_test_headless_input_contract()
	_test_all_modes_roundtrip()
	_test_persistent_store()
	_test_dedicated_roster_contract()
	_test_stale_remote_players_are_pruned()
	_test_silent_peer_recovery_contract()
	_test_authoritative_inventory_reconciliation()
	_test_dedicated_weather_targets_real_players()
	_test_fake_player_flag_contract()
	_test_headless_rehost_backoff_contract()
	_cleanup()
	if failures == 0:
		print("PASS: all five modes boot and round-trip, persistence reloads, dedicated host stays hidden")
	get_tree().quit(failures)


func _test_headless_input_contract() -> void:
	for action: String in ["move_left", "move_right", "jump"]:
		_assert(InputMap.has_action(action), "headless project defines %s input action" % action)


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


func _test_stale_remote_players_are_pruned() -> void:
	var now_msec := 100_000
	var remote_players := {
		"active-player": {"_received_msec": now_msec - 100},
		"stale-player": {"_received_msec": now_msec - 30_000},
		"legacy-placeholder": {},
	}
	var stale_ids := ServerMainClass.stale_remote_player_ids(remote_players, now_msec)
	_assert(stale_ids == ["legacy-placeholder", "stale-player"], "disconnected player snapshots cannot remain as motionless host avatars")


func _test_silent_peer_recovery_contract() -> void:
	_assert(
		MultiplayerClientClass.rtc_silence_recovery_mode(true, true)
		== MultiplayerClientClass.RTC_SILENCE_RECOVERY_WEBSOCKET,
		"a silent dedicated guest falls back to WebSocket instead of freezing",
	)
	_assert(
		MultiplayerClientClass.rtc_silence_recovery_mode(true, false)
		== MultiplayerClientClass.RTC_SILENCE_RECOVERY_RECONNECT,
		"a silent P2P guest reconnects when relay fallback is unavailable",
	)
	_assert(
		MultiplayerClientClass.rtc_silence_recovery_mode(false, true)
		== MultiplayerClientClass.RTC_SILENCE_RECOVERY_DROP_PEER,
		"a host drops a silent peer so authoritative state switches to the relay",
	)
	_assert(
		not MultiplayerClientClass.rtc_packet_refreshes_watchdog(false, "command", "player_input"),
		"guest commands do not hide a broken host-to-guest RTC path",
	)
	_assert(
		MultiplayerClientClass.rtc_packet_refreshes_watchdog(false, "control", "p2p_pong"),
		"a pong proves the host RTC path works in both directions",
	)


func _test_authoritative_inventory_reconciliation() -> void:
	var authoritative := {
		"inventory_host_revision": 4,
		"inventory_client_revision": 1,
		"inventory": {"stone": 3},
	}
	var stale_guest_snapshot := {
		"inventory_host_revision": 3,
		"inventory_client_revision": 2,
		"inventory": {},
	}
	var reconciled: Dictionary = ServerMainClass.reconcile_stale_inventory_ack(authoritative, stale_guest_snapshot)
	_assert(int(reconciled.get("inventory_client_revision", 0)) == 2, "stale guest mutations cannot make it reject the latest mining award")
	_assert(int((reconciled.get("inventory", {}) as Dictionary).get("stone", 0)) == 3, "stale guest snapshots cannot erase authoritative mining drops")


func _test_dedicated_weather_targets_real_players() -> void:
	var sim := WorldSim.new()
	sim.create_island()
	sim.weather_uses_local_player = false
	sim.weather_type = "rain"
	sim.weather_ticks_remaining = 10
	sim.tick_weather()
	_assert(sim.weather_type == "clear", "empty dedicated worlds clear weather instead of raining on the hidden host")
	var remote_tile := Vector2i(120, 10)
	sim.set_block(remote_tile.x, remote_tile.y + 1, BlockDefs.BLOCKS.stone.id)
	sim.multiplayer_player_targets["guest"] = {
		"x": float(remote_tile.x * BlockDefs.TILE),
		"y": float(remote_tile.y * BlockDefs.TILE),
		"w": 20.0,
		"h": 28.0,
		"health": WorldSim.MAX_PLAYER_HEALTH,
	}
	var target = sim._find_rain_target()
	_assert(target is Vector2i and Vector2((target as Vector2i) - remote_tile).length() <= float(WorldSim.WEATHER_TARGET_RADIUS), "dedicated weather follows a connected real player")


func _test_fake_player_flag_contract() -> void:
	_assert(ServerMainClass.normalized_fake_player_count(0) == 0, "filming bots are disabled by default")
	_assert(ServerMainClass.normalized_fake_player_count(10) == 10, "the filming setup accepts ten fake players")
	_assert(ServerMainClass.normalized_fake_player_count(99) == 10, "the filming setup cannot exceed ten fake players")
	_assert(ServerMainClass.normalized_fake_player_count(-1) == 0, "negative fake-player values stay disabled")
	_assert(ServerMainClass.fake_player_jump_height() > 90.0, "filming bots use the full standard player jump height")
	_assert(not ServerMainClass.natural_spawning_enabled_for_remote_players({}), "an empty dedicated world cannot accumulate natural creatures")
	_assert(ServerMainClass.natural_spawning_enabled_for_remote_players({"guest": {}}), "one real player enables natural creature spawning")
	var crowded_players := {}
	for index in 10:
		crowded_players["guest_%d" % index] = {}
	_assert(ServerMainClass.natural_spawning_enabled_for_remote_players(crowded_players), "ten nearby players do not multiply the natural spawn gate")


func _test_headless_rehost_backoff_contract() -> void:
	var first_delay := ServerMainClass.headless_rehost_retry_delay(1)
	var second_delay := ServerMainClass.headless_rehost_retry_delay(2)
	var third_delay := ServerMainClass.headless_rehost_retry_delay(3)
	_assert(is_equal_approx(first_delay, ServerMainClass.HEADLESS_RETRY_SECONDS), "the first rehost retry keeps the short initial delay")
	_assert(second_delay > first_delay and third_delay > second_delay, "rehost retries use exponential backoff")
	_assert(
		ServerMainClass.headless_rehost_retry_delay(100, 1.0) <= ServerMainClass.HEADLESS_RETRY_MAX_SECONDS,
		"rehost backoff is capped even with positive jitter",
	)
	_assert(
		ServerMainClass.headless_rehost_retry_delay(2, -1.0)
		< ServerMainClass.headless_rehost_retry_delay(2, 0.0),
		"rehost retries apply bounded negative jitter",
	)
	var server := ServerMainClass.new()
	server._headless_server = true
	server._headless_rehost_attempt = 3
	server._headless_rehost_time_left = 12.0
	server._headless_rehost_in_flight = true
	server._headless_connection_pending = true
	server._headless_connection_time_left = 9.0
	server._on_headless_connected("host", "headless-host", "server-test")
	_assert(server._headless_rehost_attempt == 0, "successful connected resets the retry attempt")
	_assert(server._headless_rehost_time_left < 0.0, "successful connected cancels the retry timer")
	_assert(not server._headless_rehost_in_flight, "successful connected clears session creation in-flight state")
	_assert(not server._headless_connection_pending, "successful connected clears transport pending state")
	server.free()
	var guarded_server := ServerMainClass.new()
	guarded_server._headless_server = true
	guarded_server._world_started = true
	guarded_server._headless_rehost_in_flight = true
	guarded_server._headless_connect_host()
	_assert(guarded_server._headless_rehost_in_flight, "an in-flight session request cannot start a duplicate request")
	guarded_server._headless_rehost_in_flight = false
	guarded_server._headless_connection_pending = true
	guarded_server._headless_connect_host()
	_assert(guarded_server._headless_connection_pending, "a pending transport cannot start a duplicate session")
	guarded_server.free()


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
