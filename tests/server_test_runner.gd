extends Node

const WorldSim = preload("res://gameplay/scripts/world.gd")
const WorldStoreClass = preload("res://gameplay/scripts/world_store.gd")
const MultiplayerClientClass = preload("res://gameplay/scripts/multiplayer_client.gd")
const ServerMainClass = preload("res://scripts/server_main.gd")
const SpawnSelector = preload("res://scripts/community_spawn_selector.gd")

var failures := 0
var test_dir := "user://tinyblock-server-tests"


func _ready() -> void:
	failures += load("res://tests/community_spawn_selector_tests.gd").run_tests()
	_test_first_join_spawn_contract()
	_test_avatar_appearance_contract()
	_test_headless_input_contract()
	_test_loaded_host_low_bounce_takeoff()
	_test_all_modes_roundtrip()
	_test_persistent_store()
	_test_dedicated_roster_contract()
	_test_stale_remote_players_are_pruned()
	_test_silent_peer_recovery_contract()
	_test_authoritative_inventory_reconciliation()
	_test_join_inventory_snapshot_state()
	_test_snapshot_send_queue_liveness()
	_test_mining_progress_target_validation()
	_test_dedicated_weather_targets_real_players()
	_test_fake_player_flag_contract()
	_test_headless_rehost_backoff_contract()
	_cleanup()
	if failures == 0:
		print("PASS: all five modes boot and round-trip, persistence reloads, dedicated host stays hidden")
	get_tree().quit(failures)


func _test_loaded_host_low_bounce_takeoff() -> void:
	var sim := WorldSim.new()
	sim.set_block(0, 8, int(BlockDefs.BLOCKS.planks.id))
	sim.set_block(1, 7, int(BlockDefs.BLOCKS.workbench.id))
	sim.player.x = 12.0
	sim.player.y = 228.0
	sim.player.vx = 0.0
	sim.player.vy = -0.171
	sim.player.on_ground = false
	sim.player.jump_coyote = 0.0
	var min_y := 228.0
	for frame in range(45):
		sim.move_player(false, true, true, 1.0 / 20.0)
		min_y = minf(min_y, float(sim.player.y))
	_assert(min_y < 190.0 and float(sim.player.x) > 18.0, "loaded host settles microscopic floor rebounds and permits a real step-up jump")


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


func _test_join_inventory_snapshot_state() -> void:
	var active_states := {"other_guest": {"x": 12.0}}
	var saved_states := {
		"joining_guest": {"inventory": {"bow": 1, "arrow": 12}, "inventory_host_revision": 4},
		"offline_guest": {"inventory": {"stone": 3}},
	}
	var snapshot_states: Dictionary = ServerMainClass.snapshot_player_states_for_join(
		active_states,
		saved_states,
		"joining_guest",
	)
	_assert(snapshot_states.has("joining_guest"), "dedicated initial snapshot includes the joining player's saved state")
	_assert(
		int((snapshot_states["joining_guest"] as Dictionary).get("inventory", {}).get("bow", 0)) == 1,
		"dedicated initial snapshot preserves the joining player's inventory",
	)
	_assert(not snapshot_states.has("offline_guest"), "dedicated initial snapshot does not leak inactive inventories")


func _test_snapshot_send_queue_liveness() -> void:
	var queue: Array[Dictionary] = [
		{"type": "snapshot_start", "payload": {"transfer_id": "disconnected-transfer"}, "target": "disconnected-guest"},
		{"type": "snapshot_chunk", "payload": {"transfer_id": "disconnected-transfer", "index": 0}, "target": "disconnected-guest"},
		{"type": "snapshot_start", "payload": {"transfer_id": "guest-a-transfer"}, "target": "guest-a"},
		{"type": "snapshot_chunk", "payload": {"transfer_id": "guest-a-transfer", "index": 0}, "target": "guest-a"},
		{"type": "snapshot_complete", "payload": {"transfer_id": "guest-a-transfer"}, "target": "guest-a"},
		{"type": "snapshot_start", "payload": {"transfer_id": "guest-b-transfer"}, "target": "guest-b"},
		{"type": "snapshot_complete", "payload": {"transfer_id": "guest-b-transfer"}, "target": "guest-b"},
		{"type": "region_start", "payload": {"transfer_id": "expired-transfer"}, "target": "guest-c"},
	]
	var transfers := {
		"disconnected-transfer": {"target_player_id": "disconnected-guest", "expires_at": 2000},
		"guest-a-transfer": {"target_player_id": "guest-a", "expires_at": 2000},
		"guest-b-transfer": {"target_player_id": "guest-b", "expires_at": 2000},
		"expired-transfer": {"target_player_id": "guest-c", "expires_at": 999},
	}
	var pruned: Dictionary = ServerMainClass.prune_snapshot_send_state(queue, transfers, ["guest-a", "guest-b", "guest-c"], 1000)
	var active_queue: Array[Dictionary] = pruned.get("queue", [])
	var active_transfers: Dictionary = pruned.get("transfers", {})
	_assert(active_queue.size() == 5, "snapshot queue prunes disconnected-target and expired-transfer messages")
	_assert(str(active_queue[0].get("target", "")) == "guest-a", "a stale front transfer cannot block the next live guest")
	_assert(not active_transfers.has("disconnected-transfer"), "disconnect cleanup removes the outgoing transfer")
	_assert(not active_transfers.has("expired-transfer"), "expiry cleanup removes the outgoing transfer")
	_assert(active_transfers.has("guest-a-transfer") and active_transfers.has("guest-b-transfer"), "live unexpired transfers remain available")

	var after_transient_failure := ServerMainClass.snapshot_send_queue_after_attempt(active_queue, false, true)
	_assert(after_transient_failure.size() == active_queue.size(), "a valid peer's transient send failure retains every queued message")
	_assert(str(after_transient_failure[0].get("target", "")) == "guest-b", "a temporarily unavailable peer yields to another guest")
	_assert(str(after_transient_failure[2].get("target", "")) == "guest-a", "the live peer's ordered messages remain queued for retry")
	var after_other_guest_start_succeeds := ServerMainClass.snapshot_send_queue_after_attempt(after_transient_failure, true, true)
	var after_other_guest_transfer_succeeds := ServerMainClass.snapshot_send_queue_after_attempt(after_other_guest_start_succeeds, true, true)
	_assert(str(after_other_guest_transfer_succeeds[0].get("target", "")) == "guest-a", "the temporarily unavailable guest is retried after the other transfer progresses")
	var after_retry_succeeds := ServerMainClass.snapshot_send_queue_after_attempt(after_other_guest_transfer_succeeds, true, true)
	_assert(str(after_retry_succeeds[0].get("type", "")) == "snapshot_chunk", "successful retry advances within the original transfer order")

	var client := MultiplayerClientClass.new()
	client._handle_connected({
		"role": "host",
		"player_id": "headless-host",
		"session_id": "server-test",
		"players": [
			{"player_id": "headless-host", "role": "host"},
			{"player_id": "guest-a", "role": "guest"},
			{"player_id": "guest-b", "role": "guest"},
			{"player_id": "unknown-role", "role": "spectator"},
		],
	})
	_assert(client.guest_peer_ids() == ["guest-a", "guest-b"], "host liveness lists only known guest peers")
	client._handle_ws_packet(JSON.stringify({"kind": "control", "type": "player_left", "player_id": "guest-a"}).to_utf8_buffer())
	_assert(client.guest_peer_ids() == ["guest-b"], "a departed guest is removed from queue liveness immediately")
	client.free()

	_test_snapshot_send_queue_tick_uses_peer_liveness()


func _test_snapshot_send_queue_tick_uses_peer_liveness() -> void:
	var client: Node = get_node("/root/MultiplayerClient")
	var previous_role := str(client.get("role"))
	var previous_player_id := str(client.get("player_id"))
	var previous_known_players: Dictionary = client.get("_known_players").duplicate(true)
	var previous_websocket_fallback := bool(client.get("websocket_fallback_enabled"))
	client.set("role", "host")
	client.set("player_id", "headless-host")
	client.set("_known_players", {"headless-host": "host", "guest-a": "guest", "guest-b": "guest"})
	client.set("websocket_fallback_enabled", false)

	var server := ServerMainClass.new()
	var expiry := Time.get_ticks_msec() + 60_000
	var stale_front_queue: Array[Dictionary] = [
		{"type": "snapshot_start", "payload": {"transfer_id": "dead-transfer"}, "target": "dead-guest"},
		{"type": "snapshot_start", "payload": {"transfer_id": "live-a-transfer"}, "target": "guest-a"},
	]
	server.set("_snapshot_send_queue", stale_front_queue)
	server.set("_snapshot_outgoing_transfers", {
		"dead-transfer": {"target_player_id": "dead-guest", "expires_at": expiry},
		"live-a-transfer": {"target_player_id": "guest-a", "expires_at": expiry},
	})
	server.call("_tick_snapshot_send_queue", 1.0)
	var after_stale_front: Array = server.get("_snapshot_send_queue")
	_assert(after_stale_front.size() == 1, "the send tick prunes a disconnected front transfer before attempting a send")
	_assert(str(after_stale_front[0].get("target", "")) == "guest-a", "the first live guest advances after stale-front cleanup")
	_assert(str(after_stale_front[0].get("payload", {}).get("transfer_id", "")) == "live-a-transfer", "stale-front cleanup preserves the live guest transfer")
	server.free()

	client.set("role", previous_role)
	client.set("player_id", previous_player_id)
	client.set("_known_players", previous_known_players)
	client.set("websocket_fallback_enabled", previous_websocket_fallback)


func _test_mining_progress_target_validation() -> void:
	var sim := WorldSim.new()
	sim.create_island()
	var target := Vector2i(WorldSim.COORD_LIMIT + 1, WorldSim.COORD_LIMIT + 1)
	for raw_pos in sim.tiles.keys():
		var candidate := raw_pos as Vector2i
		if sim.block_id(candidate.x, candidate.y) != 0:
			target = candidate
			break
	_assert(target.x <= WorldSim.COORD_LIMIT, "mining validation finds a solid target tile")
	if target.x > WorldSim.COORD_LIMIT:
		return
	var block := sim.get_block(target.x, target.y)
	var payload := {"x": target.x, "y": target.y, "stage": 2, "block_name": str(block.get("name", ""))}
	_assert(ServerMainClass.mining_progress_target_is_present(sim, payload), "progress is valid while its block exists")
	sim.set_block(target.x, target.y, 0)
	_assert(not ServerMainClass.mining_progress_target_is_present(sim, payload), "progress is rejected after its block disappears")


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


func _test_avatar_appearance_contract() -> void:
	var server := ServerMainClass.new()
	var view = load("res://gameplay/scripts/game_view.gd").new()
	server.game_view = view
	var skin := {
		"skin": "#70402d", "shirt": "#ed5926", "shirt_dark": "#a72e18",
		"accent": "#ffd35a", "pants": "#34252c", "hair": "#24191c",
		"body_shape": "boxy", "face": "mustache", "antenna": "twin",
		"arms": "long", "legs": "spring", "particles": "fire",
	}
	var expected: Dictionary = server._validated_multiplayer_skin(skin)
	for key in ServerMainClass.MULTIPLAYER_SKIN_ENUMS:
		_assert(expected[key] == skin[key], "dedicated server preserves avatar %s" % key)
	server._accept_remote_player_snapshot("avatar-test", {"x": 0.0, "y": 0.0, "skin": skin})
	_assert(server._remote_players["avatar-test"]["skin"] == expected, "dedicated host accepts the full customized avatar")
	_assert(view.sim.multiplayer_player_states["avatar-test"]["skin"] == expected, "dedicated host persists appearance for reconnect")
	server._remote_players["avatar-test"]["_input_authoritative"] = true
	server._accept_remote_player_snapshot("avatar-test", {"skin": {"particles": "stars"}})
	_assert(server._remote_players["avatar-test"]["skin"]["particles"] == "stars" and server._remote_players["avatar-test"]["skin"]["body_shape"] == "boxy", "input-authoritative appearance updates retain prior valid options")
	var legacy: Dictionary = server._validated_multiplayer_skin({"skin": "#70402d"})
	_assert(legacy["body_shape"] == "classic" and legacy["particles"] == "none", "legacy appearances gain safe defaults")
	var invalid: Dictionary = server._validated_multiplayer_skin({"skin": "x".repeat(1000), "body_shape": "giant", "particles": "lava", "unknown": true})
	_assert(not invalid.has("skin") and not invalid.has("unknown") and invalid["body_shape"] == "classic" and invalid["particles"] == "none", "invalid avatar fields are bounded and sanitized")
	server.free()
	view.free()


func _test_first_join_spawn_contract() -> void:
	var server := ServerMainClass.new()
	var view = load("res://gameplay/scripts/game_view.gd").new()
	server.game_view = view
	server._headless_server = true
	server._world_started = true
	var sim = view.sim
	sim.world_id = "world_spawn_contract"
	sim.world_mode = WorldSim.WORLD_MODE_SKYBLOCK
	sim.default_spawn = Vector2i(0, 8)
	for x in range(8, 29):
		for y in range(8, 12):
			sim.set_block(x, y, int(BlockDefs.BLOCKS.grass.id) if y == 8 else int(BlockDefs.BLOCKS.dirt.id))
	sim.set_block(22, 7, int(BlockDefs.BLOCKS.wood.id))
	sim.set_block(22, 6, int(BlockDefs.BLOCKS.wood.id))
	var original_spawn: Vector2i = sim.default_spawn
	sim.multiplayer_player_states["inventory-only"] = {"inventory": {"planks": 3}, "health": 9}
	_assert(server._ensure_first_join_spawn("inventory-only"), "a player without saved coordinates receives a fresh safe position")
	var allocated: Dictionary = sim.multiplayer_player_states["inventory-only"].duplicate(true)
	_assert(float(allocated.get("x", 0)) > 200.0, "new player starts on intact ground away from the ruined center")
	_assert(allocated.get("inventory", {}) == {"planks": 3} and int(allocated.get("health", 0)) == 9, "legacy inventory-only state retains items and health")
	var allocated_checkpoint: Dictionary = server._community_player_spawns.get("inventory-only", {})
	_assert(allocated_checkpoint == {"x": floori((float(allocated["x"]) + 10.0) / float(BlockDefs.TILE)), "y": floori((float(allocated["y"]) + 28.0) / float(BlockDefs.TILE))}, "first join pins a personal supporting tile")
	_assert(sim.default_spawn == original_spawn, "first join allocation does not move the shared respawn point")
	var allocation_counts: Dictionary = server._community_spawn_allocations.duplicate(true)
	_assert(not server._ensure_first_join_spawn("inventory-only") and server._community_spawn_allocations == allocation_counts, "snapshot retries do not move or count the same newcomer twice")
	server._accept_remote_player_snapshot("inventory-only", {"x": 0.0, "y": 0.0, "respawn_revision": 0})
	_assert(is_equal_approx(float(server._remote_players["inventory-only"]["x"]), float(allocated["x"])), "stale first client coordinates cannot undo the server-selected start")
	_assert(int(server._remote_players["inventory-only"]["respawn_revision"]) > 0, "standard authoritative revision confirms the new start to clients")
	sim.multiplayer_player_states["returning"] = {"x": -120.0, "y": 228.0, "inventory": {"wood": 4}}
	_assert(not server._ensure_first_join_spawn("returning") and float(sim.multiplayer_player_states["returning"]["x"]) == -120.0, "returning players keep their saved position")
	var persisted: Dictionary = JSON.parse_string(JSON.stringify(server._serialize_community_world()))
	server._community_spawn_allocations.clear()
	server._community_player_spawns.clear()
	server._load_community_spawn_history(persisted)
	_assert(server._community_spawn_allocations == allocation_counts, "allocation history survives JSON save/load across restart")
	_assert(server._community_player_spawns["inventory-only"] == allocated_checkpoint, "personal checkpoint survives the server-only save metadata")
	var restored_view = load("res://gameplay/scripts/game_view.gd").new()
	_assert(restored_view.sim.deserialize_state(persisted), "a fresh world instance reloads before personal respawn")
	var restored_server := ServerMainClass.new()
	restored_server.game_view = restored_view
	restored_server._world_started = true
	restored_server._load_community_spawn_history(persisted)
	restored_view.sim.keep_inventory_on_death = true
	restored_server._remote_players["inventory-only"] = {
		"x": 0.0, "y": 0.0, "health": 0, "respawn_revision": 4,
	}
	restored_server._perform_remote_player_respawn("inventory-only")
	var restored_target: Dictionary = restored_server._remote_players["inventory-only"]
	var respawned_tile := Vector2i(
		floori((float(restored_target["x"]) + 10.0) / float(BlockDefs.TILE)),
		floori((float(restored_target["y"]) + 28.0) / float(BlockDefs.TILE)),
	)
	_assert(respawned_tile == Vector2i(int(allocated_checkpoint["x"]), int(allocated_checkpoint["y"])), "death after restart returns a new player to the same personal checkpoint")
	_assert(int(restored_target["respawn_revision"]) == 5 and int(restored_target["health"]) == WorldSim.MAX_PLAYER_HEALTH, "the personal respawn is authoritative and increments the normal revision")
	var original_checkpoint := Vector2i(int(allocated_checkpoint["x"]), int(allocated_checkpoint["y"]))
	restored_view.sim.set_block(original_checkpoint.x, original_checkpoint.y, 0)
	restored_view.sim.set_block(original_checkpoint.x, original_checkpoint.y - 1, int(BlockDefs.BLOCKS.stone.id))
	restored_view.sim.set_block(original_checkpoint.x, original_checkpoint.y - 2, int(BlockDefs.BLOCKS.stone.id))
	restored_server._perform_remote_player_respawn("inventory-only")
	var replacement_target: Dictionary = restored_server._remote_players["inventory-only"]
	var replacement := Vector2i(
		floori((float(replacement_target["x"]) + 10.0) / float(BlockDefs.TILE)),
		floori((float(replacement_target["y"]) + 28.0) / float(BlockDefs.TILE)),
	)
	_assert(replacement != original_checkpoint and original_checkpoint.distance_to(replacement) <= 4.0, "a destroyed personal checkpoint is replaced with nearby safe terrain")
	_assert(SpawnSelector.is_spawn_safe(restored_view.sim, replacement, {}), "replacement checkpoint remains free of hazards and obstructions")
	_assert(restored_server._community_player_spawns["inventory-only"] == {"x": replacement.x, "y": replacement.y}, "the repaired checkpoint is saved for future deaths")
	restored_server.free()
	restored_view.free()

	# v0.2.27 players have no marker. Their death location is only a search
	# anchor; the selector chooses a safe tile before the server moves them.
	var legacy_server := ServerMainClass.new()
	var legacy_view = load("res://gameplay/scripts/game_view.gd").new()
	legacy_server.game_view = legacy_view
	_assert(legacy_view.sim.deserialize_state(persisted), "legacy respawn test restores the same world")
	legacy_view.sim.keep_inventory_on_death = true
	legacy_server._world_started = true
	legacy_server._load_community_spawn_history(persisted)
	legacy_server._community_player_spawns.erase("legacy-v027")
	legacy_server._remote_players["legacy-v027"] = {
		"x": float(original_spawn.x * BlockDefs.TILE),
		"y": float(original_spawn.y * BlockDefs.TILE) - 28.0,
		"health": 0,
		"respawn_revision": 0,
	}
	var legacy_death_x := float(legacy_server._remote_players["legacy-v027"]["x"])
	legacy_server._perform_remote_player_respawn("legacy-v027")
	var legacy_target: Dictionary = legacy_server._remote_players["legacy-v027"]
	var legacy_tile := Vector2i(
		floori((float(legacy_target["x"]) + 10.0) / float(BlockDefs.TILE)),
		floori((float(legacy_target["y"]) + 28.0) / float(BlockDefs.TILE)),
	)
	_assert(float(legacy_target["x"]) != legacy_death_x and legacy_server._community_player_spawns.has("legacy-v027"), "an old player gets a selected checkpoint at first death without being moved on join")
	_assert(SpawnSelector.is_spawn_safe(legacy_view.sim, legacy_tile, {}), "legacy first-death checkpoint is safe")
	legacy_server.free()
	legacy_view.free()
	server._load_community_spawn_history({})
	_assert(server._community_spawn_allocations.is_empty(), "another world or a legacy save does not inherit allocation history")
	_assert(server._community_player_spawns.is_empty(), "another world or a legacy save does not inherit personal checkpoints")
	server._load_community_spawn_history({"community_spawn": {"version": 1, "allocations": {"valid": 2, "bad": "oops", "negative": -1}}})
	_assert(server._community_spawn_allocations == {"valid": 2}, "malformed history counters are ignored")
	_assert(not ServerMainClass._has_saved_spawn_position({"x": NAN, "y": 0}) and not ServerMainClass._has_saved_spawn_position({"x": "invalid", "y": 0}), "invalid legacy coordinates are not treated as a valid return location")
	sim.world_mode = WorldSim.WORLD_MODE_ONE_BLOCK
	server._community_player_spawns["canonical-new"] = {"x": 22, "y": 8}
	_assert(server._get_or_select_personal_spawn("canonical-new", {"x": 0.0, "y": 0.0}).is_empty(), "personal community checkpoints do not override One Block canonical respawns")
	var canonical_history := server._community_spawn_allocations.duplicate(true)
	_assert(not server._ensure_first_join_spawn("canonical-new") and not server._ensure_first_join_spawn("canonical-new"), "canonical-mode joins and retries keep their original spawning")
	_assert(server._first_join_spawn_attempted.has("canonical-new") and server._community_spawn_allocations == canonical_history, "failed or canonical selection is attempted only once per newcomer, without repeated frontier generation")

	server.free()
	view.free()
