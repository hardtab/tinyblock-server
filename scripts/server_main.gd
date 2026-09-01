extends Control
# Dedicated Tiny Block server entry point.
# Runs headless: reuses the authoritative WorldSim simulation and the complete
# multiplayer host message handling from the official client, without GUI.

const WorldSim = preload("res://gameplay/scripts/world.gd")
const WorldStoreClass = preload("res://gameplay/scripts/world_store.gd")
const EmojiReactionsClass = preload("res://gameplay/scripts/emoji_reactions.gd")
const HEADLESS_SERVER_ARG := "--tinyblock-server"
const HEADLESS_WORLD_ARG := "--world"
const HEADLESS_MODE_ARG := "--world-mode"
const HEADLESS_NAME_ARG := "--world-name"
const HEADLESS_MAX_PLAYERS_ARG := "--max-players"
const HEADLESS_RETRY_SECONDS := 5.0
const HEADLESS_MAX_FPS := 30
const AUTOSAVE_MIN_INTERVAL := 5.0
const AUTOSAVE_IDLE_DELAY := 2.0
const AUTOSAVE_MAX_INTERVAL := 60.0
const LARGE_WORLD_TILE_THRESHOLD := 50_000
const LARGE_WORLD_AUTOSAVE_MIN_INTERVAL := 30.0
const LARGE_WORLD_AUTOSAVE_IDLE_DELAY := 8.0
const LARGE_WORLD_AUTOSAVE_MAX_INTERVAL := 120.0
const CATALOG_SYNC_INTERVAL := 2.0
const CATALOG_RETRY_INTERVAL := 10.0
const CATALOG_PREFETCH_RADIUS := 1
const CONTENT_REFRESH_INTERVAL := 60.0
const MULTIPLAYER_SNAPSHOT_INTERVAL := 0.1
const MULTIPLAYER_CREATURE_SNAPSHOT_INTERVAL := 0.2
const MULTIPLAYER_WORLD_CHUNK_INTERVAL := 0.075
const MULTIPLAYER_SKIN_KEYS := ["skin", "shirt", "shirt_dark", "accent", "pants", "hair"]

@onready var game_view: Node2D = $SubViewportContainer/SubViewport/GameView

var _world_store := WorldStoreClass.new()
var _world_started := false
var _world_dirty := false
var _autosave_timer := 0.0
var _autosave_idle_timer := 0.0
var _last_saved_player_position := Vector2.ZERO
var _headless_server := false
var _headless_rehost_time_left := -1.0
var _headless_world_id := ""
var _headless_world_mode := WorldSim.WORLD_MODE_SKYBLOCK
var _headless_world_name := "Tiny Block Community"
var _headless_max_players := 16
var _remote_players: Dictionary = {}
var _snapshot_outgoing_transfers: Dictionary = {}
var _snapshot_send_queue: Array[Dictionary] = []
var _snapshot_send_time_left := 0.0
var _pending_tile_deltas: Dictionary = {}
var _pending_plant_deltas: Dictionary = {}
var _pvp_cooldowns: Dictionary = {}
var _remote_respawn_protected_until_msec: Dictionary = {}
var _catalog_sync_time_left := 0.0
var _content_refresh_time_left := 0.0
var _catalog_sync_in_flight := false
var _catalog_sync_run_id := 0
var _applying_multiplayer_state := false
var _local_respawn_revision := 0
var _local_inventory_host_revision := 0
var _local_inventory_client_revision := 0
var _multiplayer_guest := false
var _emoji_sender_cooldowns: Dictionary = {}
var _multiplayer_creature_time_left := 0.0
var _multiplayer_position_time_left := 0.0


func _ready() -> void:
	if not _is_headless_server_requested():
		push_error("Tiny Block server requires --tinyblock-server argument")
		get_tree().quit(1)
		return
	_start_headless_server()


func _is_headless_server_requested() -> bool:
	return (
		DisplayServer.get_name() == "headless"
		or OS.has_feature("dedicated_server")
		or HEADLESS_SERVER_ARG in OS.get_cmdline_args()
		or HEADLESS_SERVER_ARG in OS.get_cmdline_user_args()
	)


func _headless_argument(name: String, fallback: String = "") -> String:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()
	var idx := args.find(name)
	if idx < 0 or idx + 1 >= args.size():
		return fallback
	return args[idx + 1]


func _start_headless_server() -> void:
	_headless_server = true
	Engine.max_fps = HEADLESS_MAX_FPS
	set_process(true)
	_headless_world_id = _headless_argument(HEADLESS_WORLD_ARG, "world_community_1")
	if not _headless_world_id.begins_with("world_"):
		_headless_world_id = "world_%s" % _headless_world_id
	_headless_world_mode = _headless_argument(HEADLESS_MODE_ARG, WorldSim.WORLD_MODE_SKYBLOCK)
	_headless_world_name = _headless_argument(HEADLESS_NAME_ARG, "Tiny Block Community")
	_headless_max_players = int(_headless_argument(HEADLESS_MAX_PLAYERS_ARG, "16"))
	if _headless_max_players < 1:
		push_error("Headless server --max-players must be a positive integer")
		get_tree().quit(2)
		return
	if _headless_world_mode not in [
		WorldSim.WORLD_MODE_SKYBLOCK,
		WorldSim.WORLD_MODE_FLOATING_ISLANDS,
		WorldSim.WORLD_MODE_PROCEDURAL,
		WorldSim.WORLD_MODE_ONE_BLOCK,
		WorldSim.WORLD_MODE_CHALLENGE,
	]:
		_headless_world_mode = WorldSim.WORLD_MODE_SKYBLOCK
	game_view.sim.state_changed.connect(_mark_world_dirty)
	game_view.sim.inventory_changed.connect(_mark_world_dirty)
	game_view.sim.time_changed.connect(_mark_world_dirty)
	game_view.sim.tile_changed.connect(_on_multiplayer_tile_changed)
	game_view.sim.plant_changed.connect(_on_multiplayer_plant_changed)
	game_view.sim.remote_player_attacked_by_creature.connect(_on_remote_player_attacked_by_creature)
	game_view.sim.player_defeated.connect(_headless_respawn_player)
	MultiplayerClient.message_received.connect(_on_multiplayer_message)
	MultiplayerClient.connected.connect(_on_headless_connected)
	MultiplayerClient.disconnected.connect(_on_headless_disconnected)
	call_deferred("_boot_headless_world")


# ---------------------------------------------------------------------------
# World lifecycle
# ---------------------------------------------------------------------------

func _boot_headless_world() -> void:
	var loaded := _world_store.load_world(_headless_world_id)
	var started := false
	if loaded.get("ok", false):
		started = game_view.continue_world(loaded["state"])
	if not started:
		started = game_view.start_new_world(_headless_world_mode, WorldSim.ACCESS_MODE_PUBLIC, true)
		if started:
			game_view.sim.world_id = _headless_world_id
	if not started:
		push_error("Headless server could not load or create world %s" % _headless_world_id)
		get_tree().quit(1)
		return
	game_view.sim.access_mode = WorldSim.ACCESS_MODE_PUBLIC
	_world_started = true
	_world_dirty = true
	_save_world()
	_headless_rehost_time_left = 0.0
	print("Tiny Block headless server starting world %s (%s)" % [_headless_world_id, game_view.sim.world_mode])


func _headless_connect_host() -> void:
	if not _headless_server or not _world_started or MultiplayerClient.is_online():
		return
	var response := await BackendClient.create_multiplayer_session(
		game_view.sim.world_id,
		_headless_world_name,
		game_view.sim.world_mode,
		WorldSim.ACCESS_MODE_PUBLIC,
		true,
		_headless_max_players,
	)
	if not response.get("ok", false):
		push_error("Headless multiplayer session creation failed: %s" % str(response.get("error", "unknown")))
		_headless_rehost_time_left = HEADLESS_RETRY_SECONDS
		return
	var body: Dictionary = response.get("body", {})
	var session_body: Dictionary = body.get("session", {}) if body.get("session", {}) is Dictionary else {}
	game_view.sim.multiplayer_join_code = str(body.get("join_code", ""))
	_save_world()
	var error := MultiplayerClient.connect_with_ticket(
		str(body.get("websocket_url", "")),
		str(body.get("ws_ticket", "")),
		game_view.sim.multiplayer_join_code,
		bool(body.get("relay_fallback_enabled", false)),
	)
	MultiplayerClient.set_session_max_players(int(session_body.get("max_players", _headless_max_players)))
	MultiplayerClient.set_dedicated_server_session(true)
	if bool(session_body.get("official", session_body.get("is_official", false))):
		MultiplayerClient.set_session_classification("official")
	else:
		MultiplayerClient.set_session_classification("community")
	if error != OK:
		push_error("Headless multiplayer websocket connection failed: %s" % error_string(error))
		_headless_rehost_time_left = HEADLESS_RETRY_SECONDS


func _on_headless_connected(_role: String, _player_id: String, _session_id: String) -> void:
	_headless_rehost_time_left = -1.0
	print("Tiny Block headless server is online: %s" % MultiplayerClient.session_id)


func _on_headless_disconnected(reason: String) -> void:
	if not _headless_server:
		return
	print("Tiny Block headless server disconnected: %s" % reason)
	_headless_rehost_time_left = HEADLESS_RETRY_SECONDS


func _headless_respawn_player() -> void:
	if not _headless_server or not _world_started:
		return
	if int(game_view.sim.player.get("health", WorldSim.MAX_PLAYER_HEALTH)) <= 0:
		game_view.sim.respawn_player_after_defeat()
		_mark_world_dirty()


func _process(delta: float) -> void:
	if not _world_started:
		return
	if _headless_rehost_time_left >= 0.0:
		_headless_rehost_time_left -= delta
		if _headless_rehost_time_left <= 0.0:
			_headless_rehost_time_left = -1.0
			_headless_connect_host()
	elif not MultiplayerClient.is_online():
		_headless_rehost_time_left = HEADLESS_RETRY_SECONDS
	_tick_snapshot_send_queue(delta)
	_tick_multiplayer(delta)
	_autosave_timer += delta
	if _should_autosave():
		_save_world()
	_catalog_sync_time_left -= delta
	if _catalog_sync_time_left <= 0.0:
		_catalog_sync_time_left = CATALOG_SYNC_INTERVAL
		_sync_catalog_regions_near_player()


# ---------------------------------------------------------------------------
# Multiplayer message dispatch
# ---------------------------------------------------------------------------

func _on_multiplayer_message(message: Dictionary) -> void:
	var kind := str(message.get("kind", ""))
	var type := str(message.get("type", ""))
	if kind == "command" and MultiplayerClient.is_host():
		var sender := str(message.get("sender_player_id", ""))
		var command_payload: Dictionary = message.get("payload", {}) if message.get("payload", {}) is Dictionary else {}
		if type == "snapshot_request":
			_send_world_snapshot(sender)
		elif type == "snapshot_retry":
			_retry_world_snapshot(sender, command_payload)
		elif type == "player_snapshot":
			_accept_remote_player_snapshot(sender, command_payload)
		elif type == "attack_player":
			_apply_pvp_attack(sender, str(command_payload.get("target_player_id", "")))
		elif type == "player_defeated":
			_respawn_remote_player(sender, int(command_payload.get("respawn_revision", -1)))
		elif type in ["mine_block", "place_block", "attack_creature", "interact_creature", "recover_death_cache", "recover_one_use_cache"]:
			_apply_remote_world_action(sender, type, command_payload)
		elif type == "inventory_snapshot":
			_store_remote_inventory(sender, command_payload)
		elif type == "chunk_request":
			_send_requested_chunk(sender, int(command_payload.get("chunk_x", WorldSim.COORD_LIMIT)))
		elif type == "emoji_reaction":
			_accept_emoji_reaction(sender, command_payload)
		return
	if kind == "control" and type == "player_left" and MultiplayerClient.is_host():
		var left_player_id := str(message.get("player_id", ""))
		if _remote_players.get(left_player_id) is Dictionary:
			_store_remote_player_resume_state(left_player_id, _remote_players[left_player_id])
			_mark_world_dirty()
		_remote_players.erase(left_player_id)
		_remote_respawn_protected_until_msec.erase(left_player_id)
		game_view.remote_players = _remote_players


# ---------------------------------------------------------------------------
# Periodic state broadcasting (called from _process)
# ---------------------------------------------------------------------------

func _tick_multiplayer(delta: float) -> void:
	if not MultiplayerClient.is_host() or not _world_started:
		return
	_multiplayer_position_time_left -= delta
	_multiplayer_creature_time_left -= delta
	if _multiplayer_position_time_left <= 0.0:
		_multiplayer_position_time_left = MULTIPLAYER_SNAPSHOT_INTERVAL
		var players := _remote_players.duplicate(true)
		if not MultiplayerClient.is_dedicated_server_session():
			var local: Dictionary = game_view.sim.player
			players[MultiplayerClient.player_id] = {
				"x": float(local.get("x", 0.0)),
				"y": float(local.get("y", 0.0)),
				"facing": int(local.get("facing", 1)),
				"vx": float(local.get("vx", 0.0)),
				"vy": float(local.get("vy", 0.0)),
				"on_ground": bool(local.get("on_ground", false)),
				"health": int(local.get("health", WorldSim.MAX_PLAYER_HEALTH)),
				"nourishment": int(local.get("nourishment", WorldSim.MAX_NOURISHMENT)),
				"respawn_revision": _local_respawn_revision,
				"equipment_slots": _local_equipment_snapshot(),
			}
		MultiplayerClient.send_state("players_snapshot", {
			"players": players,
			"world_time_tick": game_view.sim.world_time_tick,
		})
		if not _pending_tile_deltas.is_empty():
			MultiplayerClient.send_state("tile_batch", {"tiles": _pending_tile_deltas.values()})
			_pending_tile_deltas.clear()
		if not _pending_plant_deltas.is_empty():
			MultiplayerClient.send_state("plant_batch", {"plants": _pending_plant_deltas.values()})
			_pending_plant_deltas.clear()
	if _multiplayer_creature_time_left <= 0.0:
		_multiplayer_creature_time_left = MULTIPLAYER_CREATURE_SNAPSHOT_INTERVAL
		var snapshot: Array = []
		for raw_creature_id in game_view.sim.creatures:
			var creature_id := str(raw_creature_id)
			var creature: Dictionary = game_view.sim.creatures[creature_id]
			snapshot.append([
				creature_id,
				float(creature.get("x", 0.0)),
				float(creature.get("y", 0.0)),
				int(creature.get("facing", 1)),
				int(creature.get("health", 1)),
				str(creature.get("block_name", "")),
				str(creature.get("work_action", "")),
				int(creature.get("work_action_ticks", 0)),
				int(creature.get("work_target_x", 0)),
				int(creature.get("work_target_y", 0)),
				int(creature.get("carried_materials", 0)),
			])
		MultiplayerClient.send_state("creatures_snapshot", {"creatures": snapshot})


func _local_equipment_snapshot() -> Dictionary:
	return {
		"hand": game_view.sim.equipped_item_name("hand"),
		"feet": game_view.sim.equipped_item_name("feet"),
	}


# ---------------------------------------------------------------------------
# World snapshot transfer
# ---------------------------------------------------------------------------

func _send_world_snapshot(target_player_id: String) -> void:
	if not MultiplayerClient.is_host() or target_player_id.is_empty():
		return
	_discard_queued_snapshot_messages(target_player_id)
	for raw_transfer_id in _snapshot_outgoing_transfers.keys():
		var old_transfer: Dictionary = _snapshot_outgoing_transfers[raw_transfer_id]
		if str(old_transfer.get("target_player_id", "")) == target_player_id:
			_snapshot_outgoing_transfers.erase(raw_transfer_id)
	var transfer_id := "snapshot_%d" % Time.get_ticks_msec()
	var raw := JSON.stringify(game_view.sim.serialize_state()).to_utf8_buffer()
	var encoded := Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_GZIP))
	const CHUNK_SIZE := 12000
	var total := ceili(float(encoded.length()) / float(CHUNK_SIZE))
	var chunks: Array[String] = []
	for index in total:
		chunks.append(encoded.substr(index * CHUNK_SIZE, CHUNK_SIZE))
	_snapshot_outgoing_transfers[transfer_id] = {
		"target_player_id": target_player_id,
		"chunks": chunks,
		"expires_at": Time.get_ticks_msec() + 300_000,
	}
	_queue_snapshot_chunks(transfer_id, target_player_id, range(total))


func _retry_world_snapshot(target_player_id: String, payload: Dictionary) -> void:
	var transfer_id := str(payload.get("transfer_id", ""))
	var transfer: Dictionary = _snapshot_outgoing_transfers.get(transfer_id, {})
	if transfer.is_empty() or str(transfer.get("target_player_id", "")) != target_player_id:
		_send_world_snapshot(target_player_id)
		return
	var chunks: Array = transfer.get("chunks", []) if transfer.get("chunks", []) is Array else []
	var missing: Array = payload.get("missing", []) if payload.get("missing", []) is Array else []
	var indexes: Array[int] = []
	for raw_index in missing:
		var index := int(raw_index)
		if index >= 0 and index < chunks.size() and index not in indexes:
			indexes.append(index)
	if indexes.is_empty():
		indexes.assign(range(chunks.size()))
	_discard_queued_snapshot_messages(target_player_id, transfer_id)
	_queue_snapshot_chunks(transfer_id, target_player_id, indexes)


func _discard_queued_snapshot_messages(target_player_id: String, transfer_id: String = "") -> void:
	for index in range(_snapshot_send_queue.size() - 1, -1, -1):
		var queued: Dictionary = _snapshot_send_queue[index]
		if str(queued.get("target", "")) != target_player_id:
			continue
		if not transfer_id.is_empty():
			var payload: Dictionary = queued.get("payload", {}) if queued.get("payload", {}) is Dictionary else {}
			if str(payload.get("transfer_id", "")) != transfer_id:
				continue
		_snapshot_send_queue.remove_at(index)


func _queue_snapshot_chunks(transfer_id: String, target_player_id: String, indexes: Array) -> void:
	var transfer: Dictionary = _snapshot_outgoing_transfers.get(transfer_id, {})
	var chunks: Array = transfer.get("chunks", []) if transfer.get("chunks", []) is Array else []
	if chunks.is_empty():
		return
	var metadata := {"transfer_id": transfer_id, "total": chunks.size()}
	_snapshot_send_queue.append({"type": "snapshot_start", "payload": metadata, "target": target_player_id})
	for raw_index in indexes:
		var index := int(raw_index)
		if index < 0 or index >= chunks.size():
			continue
		_snapshot_send_queue.append({
			"type": "snapshot_chunk",
			"payload": {
				"transfer_id": transfer_id,
				"total": chunks.size(),
				"index": index,
				"data": str(chunks[index]),
			},
			"target": target_player_id,
		})
	_snapshot_send_queue.append({"type": "snapshot_complete", "payload": metadata, "target": target_player_id})
	_snapshot_send_time_left = 0.0


func _tick_snapshot_send_queue(delta: float) -> void:
	var now := Time.get_ticks_msec()
	for raw_transfer_id in _snapshot_outgoing_transfers.keys():
		var transfer_id := str(raw_transfer_id)
		var transfer: Dictionary = _snapshot_outgoing_transfers[transfer_id]
		if now >= int(transfer.get("expires_at", 0)):
			_snapshot_outgoing_transfers.erase(transfer_id)
	if _snapshot_send_queue.is_empty() or not MultiplayerClient.is_host():
		return
	_snapshot_send_time_left -= delta
	if _snapshot_send_time_left > 0.0:
		return
	var message: Dictionary = _snapshot_send_queue.front()
	if MultiplayerClient.send_state(
		str(message.get("type", "")),
		message.get("payload", {}) as Dictionary,
		str(message.get("target", "")),
	):
		_snapshot_send_queue.pop_front()
		_snapshot_send_time_left = MULTIPLAYER_WORLD_CHUNK_INTERVAL


func _send_requested_chunk(target_player_id: String, chunk_x: int) -> void:
	if not MultiplayerClient.is_host() or target_player_id.is_empty() or not _remote_players.has(target_player_id):
		return
	var remote: Dictionary = _remote_players[target_player_id]
	var remote_tile_x := floori(float(remote.get("x", 0.0)) / float(BlockDefs.TILE))
	var remote_chunk_x := floori(float(remote_tile_x) / float(WorldSim.CHUNK_WIDTH))
	if absi(chunk_x - remote_chunk_x) > WorldSim.CHUNK_GENERATION_RADIUS + 1:
		return
	if not game_view.sim.ensure_generated_chunk(chunk_x):
		return
	var state: Dictionary = game_view.sim.serialize_chunk_state(chunk_x)
	if state.is_empty():
		return
	var transfer_id := "region_%d_%d" % [chunk_x, Time.get_ticks_msec()]
	var raw := JSON.stringify(state).to_utf8_buffer()
	var encoded := Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_GZIP))
	const CHUNK_SIZE := 12000
	var total := ceili(float(encoded.length()) / float(CHUNK_SIZE))
	var chunks: Array[String] = []
	for index in total:
		chunks.append(encoded.substr(index * CHUNK_SIZE, CHUNK_SIZE))
	_snapshot_outgoing_transfers[transfer_id] = {
		"target_player_id": target_player_id,
		"chunks": chunks,
		"expires_at": Time.get_ticks_msec() + 30_000,
	}
	var metadata := {"transfer_id": transfer_id, "total": total, "chunk_x": chunk_x}
	_snapshot_send_queue.append({"type": "region_start", "payload": metadata, "target": target_player_id})
	for index in total:
		_snapshot_send_queue.append({
			"type": "region_chunk",
			"payload": {
				"transfer_id": transfer_id,
				"total": total,
				"chunk_x": chunk_x,
				"index": index,
				"data": chunks[index],
			},
			"target": target_player_id,
		})
	_snapshot_send_queue.append({"type": "region_complete", "payload": metadata, "target": target_player_id})
	_snapshot_send_time_left = 0.0


# ---------------------------------------------------------------------------
# Remote player state
# ---------------------------------------------------------------------------

func _accept_remote_player_snapshot(player_id: String, raw_payload: Variant) -> void:
	if player_id.is_empty() or not raw_payload is Dictionary:
		return
	var payload := raw_payload as Dictionary
	var prior: Dictionary = _remote_players.get(player_id, {})
	var authoritative_respawn_revision := int(prior.get("respawn_revision", 0))
	var incoming_respawn_revision := int(payload.get("respawn_revision", -1))
	var legacy_respawn_protected := (
		incoming_respawn_revision < 0
		and Time.get_ticks_msec() < int(_remote_respawn_protected_until_msec.get(player_id, 0))
	)
	var stale_after_respawn := remote_snapshot_is_stale(
		authoritative_respawn_revision,
		incoming_respawn_revision,
		legacy_respawn_protected,
	)
	var x := clampf(float(payload.get("x", prior.get("x", 0.0))), -WorldSim.COORD_LIMIT * BlockDefs.TILE, WorldSim.COORD_LIMIT * BlockDefs.TILE)
	var y := clampf(float(payload.get("y", prior.get("y", 0.0))), -WorldSim.COORD_LIMIT * BlockDefs.TILE, WorldSim.COORD_LIMIT * BlockDefs.TILE)
	if stale_after_respawn:
		x = float(prior.get("x", x))
		y = float(prior.get("y", y))
	if not prior.is_empty():
		x = clampf(x, float(prior.get("x", x)) - 96.0, float(prior.get("x", x)) + 96.0)
		y = clampf(y, float(prior.get("y", y)) - 96.0, float(prior.get("y", y)) + 96.0)
	if incoming_respawn_revision >= authoritative_respawn_revision:
		_remote_respawn_protected_until_msec.erase(player_id)
	_remote_players[player_id] = {
		"x": x,
		"y": y,
		"facing": int(prior.get("facing", 1)) if stale_after_respawn else (-1 if int(payload.get("facing", 1)) < 0 else 1),
		"vx": float(prior.get("vx", 0.0)) if stale_after_respawn else clampf(float(payload.get("vx", 0.0)), -20.0, 20.0),
		"vy": float(prior.get("vy", 0.0)) if stale_after_respawn else clampf(float(payload.get("vy", 0.0)), -20.0, 20.0),
		"on_ground": bool(prior.get("on_ground", false)) if stale_after_respawn else bool(payload.get("on_ground", false)),
		"_received_msec": Time.get_ticks_msec(),
		"health": int(prior.get("health", WorldSim.MAX_PLAYER_HEALTH)) if stale_after_respawn else clampi(int(payload.get("health", prior.get("health", WorldSim.MAX_PLAYER_HEALTH))), 0, WorldSim.MAX_PLAYER_HEALTH),
		"nourishment": int(prior.get("nourishment", WorldSim.MAX_NOURISHMENT)) if stale_after_respawn else clampi(int(payload.get("nourishment", prior.get("nourishment", WorldSim.MAX_NOURISHMENT))), 0, WorldSim.MAX_NOURISHMENT),
		"respawn_revision": authoritative_respawn_revision,
		"skin": _validated_multiplayer_skin(payload.get("skin", prior.get("skin", {}))),
		"equipment_slots": _validated_multiplayer_equipment(payload.get("equipment_slots", prior.get("equipment_slots", {}))),
	}
	_store_remote_player_resume_state(player_id, _remote_players[player_id])
	game_view.remote_players = _remote_players


static func remote_snapshot_is_stale(authoritative_revision: int, incoming_revision: int, legacy_protected: bool = false) -> bool:
	return legacy_protected or (incoming_revision >= 0 and incoming_revision < authoritative_revision)


func _store_remote_player_resume_state(player_id: String, remote: Dictionary) -> void:
	if player_id.is_empty():
		return
	var state: Dictionary = game_view.sim.multiplayer_player_states.get(player_id, {}).duplicate(true) if game_view.sim.multiplayer_player_states.get(player_id, {}) is Dictionary else {}
	for key in ["x", "y", "facing", "on_ground", "health", "nourishment", "skin"]:
		if remote.has(key):
			state[key] = remote[key].duplicate(true) if remote[key] is Dictionary else remote[key]
	game_view.sim.multiplayer_player_states[player_id] = state


func _validated_multiplayer_skin(raw_skin: Variant) -> Dictionary:
	if not raw_skin is Dictionary:
		return {}
	var skin: Dictionary = {}
	for key: String in MULTIPLAYER_SKIN_KEYS:
		var value := str((raw_skin as Dictionary).get(key, ""))
		if value.length() > 16 or not Color.html_is_valid(value):
			return {}
		skin[key] = Color.from_string(value, Color.WHITE).to_html(false)
	return skin


func _validated_multiplayer_equipment(raw_equipment: Variant) -> Dictionary:
	var equipment := {"hand": "", "feet": ""}
	if not raw_equipment is Dictionary:
		return equipment
	for slot_name: String in equipment:
		var block_name := str((raw_equipment as Dictionary).get(slot_name, ""))
		if game_view.sim.equipment_slot_for_item(block_name) == slot_name:
			equipment[slot_name] = block_name
	return equipment


# ---------------------------------------------------------------------------
# Creature and PvP
# ---------------------------------------------------------------------------

func _on_remote_player_attacked_by_creature(player_id: String, damage: int, knockback_x: float, knockback_y: float) -> void:
	if not MultiplayerClient.is_host() or not _remote_players.has(player_id):
		return
	var target: Dictionary = _remote_players[player_id]
	target["health"] = maxi(0, int(target.get("health", WorldSim.MAX_PLAYER_HEALTH)) - maxi(0, damage))
	target["vx"] = knockback_x
	target["vy"] = knockback_y
	if int(target["health"]) <= 0:
		_remote_players[player_id] = target
		_respawn_remote_player(player_id)
		return
	_remote_players[player_id] = target
	game_view.remote_players = _remote_players


func _remote_weapon_damage(player_id: String) -> int:
	var state: Dictionary = game_view.sim.multiplayer_player_states.get(player_id, {}) if game_view.sim.multiplayer_player_states.get(player_id, {}) is Dictionary else {}
	var inventory: Dictionary = state.get("inventory", {}) if state.get("inventory", {}) is Dictionary else {}
	var equipment: Dictionary = state.get("equipment_slots", {}) if state.get("equipment_slots", {}) is Dictionary else {}
	var block_name := str(equipment.get("hand", ""))
	if int(inventory.get(block_name, 0)) <= 0 or not BlockDefs.BLOCKS.has(block_name):
		return 1
	var definition: Dictionary = BlockDefs.BLOCKS[block_name].get("definition", {}) if BlockDefs.BLOCKS[block_name].get("definition", {}) is Dictionary else {}
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return clampi(int(effects.get("creature_damage", 1)), 1, 5)


func _respawn_remote_player(player_id: String, requested_respawn_revision: int = -1) -> void:
	if not MultiplayerClient.is_host() or not _remote_players.has(player_id):
		return
	var authoritative_respawn_revision := int((_remote_players[player_id] as Dictionary).get("respawn_revision", 0))
	if not should_accept_guest_defeat_request(authoritative_respawn_revision, requested_respawn_revision):
		return
	_create_remote_player_death_cache(player_id)
	var target: Dictionary = _remote_players[player_id]
	target["health"] = WorldSim.MAX_PLAYER_HEALTH
	target["x"] = float(game_view.sim.player.get("x", 0.0)) + BlockDefs.TILE * 2.0
	target["y"] = float(game_view.sim.player.get("y", 0.0))
	target["vx"] = 0.0
	target["vy"] = 0.0
	target["respawn_revision"] = int(target.get("respawn_revision", 0)) + 1
	_remote_players[player_id] = target
	_remote_respawn_protected_until_msec[player_id] = Time.get_ticks_msec() + 1000
	game_view.remote_players = _remote_players
	var targeted_players: Dictionary = {}
	targeted_players[player_id] = target.duplicate(true)
	MultiplayerClient.send_state("players_snapshot", {
		"players": targeted_players,
		"world_time_tick": game_view.sim.world_time_tick,
	}, player_id)
	_mark_world_dirty()


static func should_accept_guest_defeat_request(authoritative_respawn_revision: int, requested_respawn_revision: int) -> bool:
	return requested_respawn_revision < 0 or requested_respawn_revision == authoritative_respawn_revision


func _apply_pvp_attack(attacker_id: String, target_id: String) -> void:
	if not MultiplayerClient.is_host() or attacker_id.is_empty() or target_id.is_empty() or attacker_id == target_id:
		return
	var now := Time.get_ticks_msec()
	if now < int(_pvp_cooldowns.get(attacker_id, 0)):
		return
	var attacker: Dictionary = game_view.sim.player if attacker_id == MultiplayerClient.player_id else _remote_players.get(attacker_id, {})
	var target: Dictionary = game_view.sim.player if target_id == MultiplayerClient.player_id else _remote_players.get(target_id, {})
	if attacker.is_empty() or target.is_empty():
		return
	var attacker_center := Vector2(float(attacker.get("x", 0.0)) + 10.0, float(attacker.get("y", 0.0)) + 14.0)
	var target_center := Vector2(float(target.get("x", 0.0)) + 10.0, float(target.get("y", 0.0)) + 14.0)
	if attacker_center.distance_to(target_center) > WorldSim.COMBAT_REACH:
		return
	_pvp_cooldowns[attacker_id] = now + WorldSim.COMBAT_ATTACK_COOLDOWN_MSEC
	var damage: int = game_view.sim.active_weapon_damage() if attacker_id == MultiplayerClient.player_id else _remote_weapon_damage(attacker_id)
	target["health"] = maxi(0, int(target.get("health", WorldSim.MAX_PLAYER_HEALTH)) - damage)
	MultiplayerClient.send_state("player_hit", {"target_player_id": target_id})
	target["vx"] = 3.5 if target_center.x >= attacker_center.x else -3.5
	target["vy"] = -3.0
	if int(target["health"]) <= 0:
		if target_id == MultiplayerClient.player_id:
			game_view.sim.respawn_player_after_defeat(MultiplayerClient.player_id)
			_local_respawn_revision += 1
		else:
			_remote_players[target_id] = target
			_respawn_remote_player(target_id)
			return
	if target_id != MultiplayerClient.player_id:
		_remote_players[target_id] = target


func _create_remote_player_death_cache(player_id: String) -> Dictionary:
	if player_id.is_empty() or not _remote_players.has(player_id):
		return {"created": false, "item_count": 0}
	var original_player: Dictionary = game_view.sim.player
	var original_selected: String = game_view.sim.selected
	var host_inventory_state := _capture_inventory_state()
	var guest_inventory_state: Dictionary = game_view.sim.multiplayer_player_states.get(player_id, {}) if game_view.sim.multiplayer_player_states.get(player_id, {}) is Dictionary else {}
	var remote: Dictionary = _remote_players[player_id]
	_applying_multiplayer_state = true
	_apply_inventory_state(guest_inventory_state)
	var remote_simulation_player := original_player.duplicate(true)
	for field in ["x", "y", "facing", "health", "nourishment", "vx", "vy"]:
		if remote.has(field):
			remote_simulation_player[field] = remote[field]
	game_view.sim.player = remote_simulation_player
	var result := {"created": false, "item_count": 0}
	if not game_view.sim.keep_inventory_on_death:
		result = game_view.sim.create_death_cache(player_id)
	var captured_guest_state := _capture_inventory_state()
	captured_guest_state["inventory_host_revision"] = maxi(0, int(guest_inventory_state.get("inventory_host_revision", 0))) + 1
	captured_guest_state["inventory_client_revision"] = maxi(0, int(guest_inventory_state.get("inventory_client_revision", 0)))
	for key in ["x", "y", "facing", "on_ground", "health", "nourishment", "skin"]:
		if remote.has(key):
			captured_guest_state[key] = remote[key].duplicate(true) if remote[key] is Dictionary else remote[key]
	game_view.sim.multiplayer_player_states[player_id] = captured_guest_state
	game_view.sim.player = original_player
	_apply_inventory_state(host_inventory_state)
	game_view.sim.selected = original_selected
	_applying_multiplayer_state = false
	MultiplayerClient.send_state("player_inventory", captured_guest_state, player_id)
	return result


# ---------------------------------------------------------------------------
# World action handlers (mine, place, creature interaction, death cache)
# ---------------------------------------------------------------------------

func _apply_remote_world_action(player_id: String, action: String, payload: Dictionary) -> void:
	if not _remote_players.has(player_id):
		return
	var remote: Dictionary = _remote_players[player_id]
	var original_player: Dictionary = game_view.sim.player
	var original_selected: String = game_view.sim.selected
	var host_inventory_state := _capture_inventory_state()
	var guest_inventory_state: Dictionary = game_view.sim.multiplayer_player_states.get(player_id, {}) if game_view.sim.multiplayer_player_states.get(player_id, {}) is Dictionary else {}
	var action_tx := int(payload.get("x", WorldSim.COORD_LIMIT + 1))
	var action_ty := int(payload.get("y", WorldSim.COORD_LIMIT + 1))
	var action_pos := Vector2i(action_tx, action_ty)
	var plant_anchor_before := action_pos
	var had_plant_before := false
	if game_view.sim.plant_cells.has(action_pos):
		had_plant_before = true
		plant_anchor_before = game_view.sim.plant_cells[action_pos] as Vector2i
	var action_applied := false
	_applying_multiplayer_state = true
	_apply_inventory_state(guest_inventory_state)
	var remote_simulation_player := original_player.duplicate(true)
	for field in ["x", "y", "facing", "health", "nourishment", "vx", "vy"]:
		if remote.has(field):
			remote_simulation_player[field] = remote[field]
	game_view.sim.player = remote_simulation_player
	if action == "mine_block":
		if game_view.sim.in_bounds(action_tx, action_ty) and game_view.sim.player_near(action_tx, action_ty):
			var had_block: bool = game_view.sim.block_id(action_tx, action_ty) != 0
			var had_plant: bool = not game_view.sim.plant_block_at(action_tx, action_ty).is_empty()
			var one_block_mined_before: int = game_view.sim.one_block_mined
			var break_succeeded := false
			if game_view.sim.is_death_cache_at(action_tx, action_ty):
				break_succeeded = game_view.sim.recover_death_cache(Vector2i(action_tx, action_ty), player_id)
			else:
				break_succeeded = game_view.sim.finish_break(action_tx, action_ty)
			var advanced_one_block: bool = (
				game_view.sim.world_mode == WorldSim.WORLD_MODE_ONE_BLOCK
				and action_pos == game_view.sim.one_block_position
				and game_view.sim.one_block_mined > one_block_mined_before
			)
			action_applied = break_succeeded and (
				advanced_one_block
				or (had_block and game_view.sim.block_id(action_tx, action_ty) == 0)
				or (had_plant and game_view.sim.plant_block_at(action_tx, action_ty).is_empty())
			)
	elif action == "place_block":
		var block_name := str(payload.get("block_name", ""))
		if BlockDefs.BLOCKS.has(block_name) and game_view.sim.inventory.get(block_name, 0) > 0:
			game_view.sim.selected = block_name
			action_applied = game_view.sim.place_block(action_tx, action_ty)
	elif action == "attack_creature":
		var creature_id := str(payload.get("creature_id", ""))
		if game_view.sim.creatures.has(creature_id):
			var creature: Dictionary = game_view.sim.creatures[creature_id]
			if game_view.sim.player_in_combat_range(floori(float(creature.get("x", 0.0))), floori(float(creature.get("y", 0.0)))):
				action_applied = game_view.sim.hit_creature(creature_id, game_view.sim.active_weapon_damage())
				if action_applied:
					game_view.sim.damage_equipped_item("hand")
	elif action == "interact_creature":
		var creature_id := str(payload.get("creature_id", ""))
		if game_view.sim.creatures.has(creature_id):
			action_applied = game_view.sim.try_interact_creature(creature_id)
	elif action == "recover_death_cache":
		var cache_pos := Vector2i(action_tx, action_ty)
		if game_view.sim.player_near(action_tx, action_ty) and game_view.sim.is_death_cache_at(action_tx, action_ty):
			action_applied = game_view.sim.recover_death_cache(cache_pos, player_id)
	elif action == "recover_one_use_cache":
		var cache_pos := Vector2i(action_tx, action_ty)
		if game_view.sim.player_near(action_tx, action_ty) and game_view.sim.is_one_use_cache_at(action_tx, action_ty):
			action_applied = game_view.sim.recover_one_use_cache(cache_pos)
	game_view.sim.player = original_player
	var captured_guest_state := _capture_inventory_state()
	captured_guest_state["inventory_host_revision"] = (
		maxi(0, int(guest_inventory_state.get("inventory_host_revision", 0))) + (1 if action_applied else 0)
	)
	captured_guest_state["inventory_client_revision"] = maxi(0, int(guest_inventory_state.get("inventory_client_revision", 0)))
	for key in ["x", "y", "facing", "on_ground", "health", "skin"]:
		if remote.has(key):
			captured_guest_state[key] = remote[key].duplicate(true) if remote[key] is Dictionary else remote[key]
	game_view.sim.multiplayer_player_states[player_id] = captured_guest_state
	var updated_guest_state: Dictionary = game_view.sim.multiplayer_player_states[player_id]
	_apply_inventory_state(host_inventory_state)
	game_view.sim.selected = original_selected
	_applying_multiplayer_state = false
	MultiplayerClient.send_state("player_inventory", updated_guest_state, player_id)
	if action in ["mine_block", "place_block", "recover_death_cache", "recover_one_use_cache"] and game_view.sim.in_bounds(action_tx, action_ty):
		var result_pos := Vector2i(action_tx, action_ty)
		var action_result := {
			"action": action,
			"accepted": action_applied,
			"x": action_tx,
			"y": action_ty,
			"block_id": game_view.sim.block_id(action_tx, action_ty),
			"level": game_view.sim.get_fluid_level(action_tx, action_ty),
			"falling": bool(game_view.sim.fluid_falling.get(Vector2i(action_tx, action_ty), false)),
			"container": game_view.sim.containers.get(result_pos, null).duplicate(true) if game_view.sim.containers.get(result_pos, null) is Dictionary else null,
		}
		if game_view.sim.plant_cells.has(result_pos):
			var plant_anchor_after := game_view.sim.plant_cells[result_pos] as Vector2i
			action_result["plant"] = game_view.sim.multiplayer_plant_state(plant_anchor_after)
		elif had_plant_before:
			action_result["plant"] = game_view.sim.multiplayer_plant_state(plant_anchor_before)
		MultiplayerClient.send_state("action_result", action_result, player_id)
	_mark_world_dirty()


# ---------------------------------------------------------------------------
# Tile and plant state broadcasting
# ---------------------------------------------------------------------------

func _on_multiplayer_tile_changed(x: int, y: int, block_id: int, level: int, falling: bool) -> void:
	if not MultiplayerClient.is_host():
		return
	_queue_multiplayer_tile_delta(x, y, block_id, level, falling)


func _on_multiplayer_plant_changed(anchor_x: int, anchor_y: int) -> void:
	if not MultiplayerClient.is_host():
		return
	var anchor := Vector2i(anchor_x, anchor_y)
	_pending_plant_deltas["%d:%d" % [anchor_x, anchor_y]] = game_view.sim.multiplayer_plant_state(anchor)


func _queue_multiplayer_tile_delta(x: int, y: int, block_id: int = -1, level: int = -2, falling: bool = false) -> void:
	var pos := Vector2i(x, y)
	var resolved_block_id: int = game_view.sim.block_id(x, y) if block_id < 0 else block_id
	var resolved_level: int = game_view.sim.get_fluid_level(x, y) if level == -2 else level
	_pending_tile_deltas["%d:%d" % [x, y]] = {
		"x": x,
		"y": y,
		"block_id": resolved_block_id,
		"level": resolved_level,
		"falling": falling,
		"fire_steps": int(game_view.sim.burning_tiles.get(pos, 0)),
		"container": game_view.sim.containers.get(pos, null).duplicate(true) if game_view.sim.containers.get(pos, null) is Dictionary else null,
	}


# ---------------------------------------------------------------------------
# Inventory state management
# ---------------------------------------------------------------------------

func _store_remote_inventory(player_id: String, payload: Dictionary) -> void:
	if player_id.is_empty() or not _remote_players.has(player_id):
		return
	var existing: Dictionary = game_view.sim.multiplayer_player_states.get(player_id, {}) if game_view.sim.multiplayer_player_states.get(player_id, {}) is Dictionary else {}
	var authoritative_revision := maxi(0, int(existing.get("inventory_host_revision", 0)))
	var incoming_revision := maxi(0, int(payload.get("inventory_host_revision", 0)))
	if incoming_revision != authoritative_revision:
		MultiplayerClient.send_state("player_inventory", existing, player_id)
		return
	var authoritative_client_revision := maxi(0, int(existing.get("inventory_client_revision", 0)))
	var incoming_client_revision := maxi(0, int(payload.get("inventory_client_revision", 0)))
	if payload.has("inventory_client_revision") and incoming_client_revision < authoritative_client_revision:
		MultiplayerClient.send_state("player_inventory", existing, player_id)
		return
	var state := _sanitize_inventory_state(payload)
	state["inventory_host_revision"] = authoritative_revision
	state["inventory_client_revision"] = incoming_client_revision if payload.has("inventory_client_revision") else authoritative_client_revision
	for key in ["x", "y", "facing", "on_ground", "health", "skin"]:
		if existing.has(key):
			state[key] = existing[key].duplicate(true) if existing[key] is Dictionary else existing[key]
	game_view.sim.multiplayer_player_states[player_id] = state
	MultiplayerClient.send_state("player_inventory", state, player_id)
	_mark_world_dirty()


func _capture_inventory_state() -> Dictionary:
	return {
		"inventory_host_revision": _local_inventory_host_revision,
		"inventory_client_revision": _local_inventory_client_revision,
		"inventory": game_view.sim.inventory.duplicate(true),
		"item_durability": game_view.sim.item_durability.duplicate(true),
		"footwear_wear_distance": game_view.sim.footwear_wear_distance,
		"inventory_order": game_view.sim.inv_order.duplicate(),
		"hotbar_slots": game_view.sim.hotbar_slots.duplicate(),
		"equipment_slots": game_view.sim.equipment_slots.duplicate(true),
		"active_hotbar_slot": game_view.sim.active_hotbar_slot,
		"selected": game_view.sim.selected,
		"nourishment": int(game_view.sim.player.get("nourishment", WorldSim.MAX_NOURISHMENT)),
		"craft_slots": game_view.sim.craft_slots.duplicate(),
		"craft_slot_durability": game_view.sim.craft_slot_durability.duplicate(),
	}


func _sanitize_inventory_state(raw: Dictionary) -> Dictionary:
	var inventory: Dictionary = {}
	var raw_inventory: Dictionary = raw.get("inventory", {}) if raw.get("inventory", {}) is Dictionary else {}
	for raw_name in raw_inventory:
		var block_name := str(raw_name)
		if BlockDefs.BLOCKS.has(block_name) and inventory.size() < 512:
			var amount := clampi(int(raw_inventory[raw_name]), 0, 9999)
			if amount > 0:
				inventory[block_name] = amount
	var order: Array[String] = []
	if raw.get("inventory_order", []) is Array:
		for raw_name in raw.get("inventory_order", []):
			var block_name := str(raw_name)
			if inventory.has(block_name) and block_name not in order:
				order.append(block_name)
	var hotbar: Array[String] = ["", "", "", "", "", ""]
	if raw.get("hotbar_slots", []) is Array:
		for index in mini(BlockDefs.HOTBAR_SIZE, (raw.get("hotbar_slots", []) as Array).size()):
			var block_name := str((raw.get("hotbar_slots", []) as Array)[index])
			hotbar[index] = block_name if inventory.has(block_name) else ""
	var equipment := {"hand": "", "feet": ""}
	var raw_equipment: Dictionary = raw.get("equipment_slots", {}) if raw.get("equipment_slots", {}) is Dictionary else {}
	for slot_name in equipment:
		var block_name := str(raw_equipment.get(slot_name, ""))
		equipment[slot_name] = block_name if BlockDefs.BLOCKS.has(block_name) else ""
	var craft_slots: Array = [null, null, null, null]
	if raw.get("craft_slots", []) is Array:
		for index in mini(4, (raw.get("craft_slots", []) as Array).size()):
			var value = (raw.get("craft_slots", []) as Array)[index]
			var block_name := str(value) if value != null else ""
			craft_slots[index] = block_name if BlockDefs.BLOCKS.has(block_name) else null
	var craft_slot_durability: Array[int] = [0, 0, 0, 0]
	if raw.get("craft_slot_durability", []) is Array:
		for index in mini(craft_slot_durability.size(), (raw.get("craft_slot_durability", []) as Array).size()):
			craft_slot_durability[index] = clampi(int((raw.get("craft_slot_durability", []) as Array)[index]), 0, 2000)
	return {
		"inventory_host_revision": maxi(0, int(raw.get("inventory_host_revision", 0))),
		"inventory_client_revision": maxi(0, int(raw.get("inventory_client_revision", 0))),
		"inventory": inventory,
		"item_durability": (raw.get("item_durability", {}) as Dictionary).duplicate(true) if raw.get("item_durability", {}) is Dictionary else {},
		"footwear_wear_distance": maxf(0.0, float(raw.get("footwear_wear_distance", 0.0))),
		"inventory_order": order,
		"hotbar_slots": hotbar,
		"equipment_slots": equipment,
		"active_hotbar_slot": clampi(int(raw.get("active_hotbar_slot", 0)), 0, BlockDefs.HOTBAR_SIZE - 1),
		"selected": str(raw.get("selected", "")) if inventory.has(str(raw.get("selected", ""))) else "",
		"nourishment": clampi(int(raw.get("nourishment", WorldSim.MAX_NOURISHMENT)), 0, WorldSim.MAX_NOURISHMENT),
		"craft_slots": craft_slots,
		"craft_slot_durability": craft_slot_durability,
	}


func _apply_inventory_state(raw: Dictionary) -> void:
	var state := _sanitize_inventory_state(raw)
	game_view.sim.inventory = (state["inventory"] as Dictionary).duplicate(true)
	game_view.sim.item_durability = (state["item_durability"] as Dictionary).duplicate(true)
	game_view.sim.footwear_wear_distance = float(state["footwear_wear_distance"])
	game_view.sim.inv_order.assign(state["inventory_order"])
	game_view.sim.hotbar_slots.assign(state["hotbar_slots"])
	game_view.sim.equipment_slots = (state["equipment_slots"] as Dictionary).duplicate(true)
	game_view.sim.active_hotbar_slot = int(state["active_hotbar_slot"])
	game_view.sim.selected = str(state["selected"])
	game_view.sim.player["nourishment"] = int(state["nourishment"])
	game_view.sim.craft_slots.assign(state["craft_slots"])
	game_view.sim.craft_slot_durability.assign(state["craft_slot_durability"])


# ---------------------------------------------------------------------------
# Emoji handling
# ---------------------------------------------------------------------------

func _accept_emoji_reaction(sender: String, payload: Dictionary) -> void:
	var emoji := EmojiReactionsClass.sanitize(payload.get("emoji", ""))
	var now := Time.get_ticks_msec()
	if sender.is_empty() or emoji.is_empty() or now < int(_emoji_sender_cooldowns.get(sender, 0)):
		return
	_emoji_sender_cooldowns[sender] = now + EmojiReactionsClass.SEND_COOLDOWN_MSEC
	MultiplayerClient.send_state("emoji_reaction", {"player_id": sender, "emoji": emoji})


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func _mark_world_dirty() -> void:
	if _world_started:
		_world_dirty = true


func _should_autosave() -> bool:
	if not _world_dirty:
		return false
	var large_world: bool = int(game_view.sim.block_count) >= LARGE_WORLD_TILE_THRESHOLD
	var minimum_interval: float = LARGE_WORLD_AUTOSAVE_MIN_INTERVAL if large_world else AUTOSAVE_MIN_INTERVAL
	var idle_delay: float = LARGE_WORLD_AUTOSAVE_IDLE_DELAY if large_world else AUTOSAVE_IDLE_DELAY
	var maximum_interval: float = LARGE_WORLD_AUTOSAVE_MAX_INTERVAL if large_world else AUTOSAVE_MAX_INTERVAL
	return (
		(_autosave_timer >= minimum_interval and _autosave_idle_timer >= idle_delay)
		or _autosave_timer >= maximum_interval
	)


func _save_world() -> void:
	if not _world_started or _multiplayer_guest:
		return
	if int(game_view.sim.player.get("health", WorldSim.MAX_PLAYER_HEALTH)) <= 0:
		return
	if _world_store.save_current(game_view.sim.serialize_state()):
		_world_dirty = false
		_autosave_timer = 0.0
		_autosave_idle_timer = 0.0
		_last_saved_player_position = Vector2(float(game_view.sim.player["x"]), float(game_view.sim.player["y"]))


# ---------------------------------------------------------------------------
# Catalog sync (procedural world generation)
# ---------------------------------------------------------------------------

func _sync_catalog_regions_near_player() -> void:
	if (
		_catalog_sync_in_flight
		or not _world_started
		or not BackendClient.is_configured()
	):
		_catalog_sync_time_left = CATALOG_SYNC_INTERVAL
		return
	_catalog_sync_in_flight = true
	var run_id: int = _catalog_sync_run_id
	var expected_world_id: String = str(game_view.sim.world_id)
	if _content_refresh_time_left <= 0.0:
		var known_content_ids: Array = game_view.sim.world_definition_ids.keys()
		known_content_ids.sort()
		for batch_start in range(0, known_content_ids.size(), 100):
			var batch_response := await BackendClient.get_content_batch(
				known_content_ids.slice(batch_start, mini(batch_start + 100, known_content_ids.size()))
			)
			if run_id != _catalog_sync_run_id or not _world_started or game_view.sim.world_id != expected_world_id:
				return
			if not batch_response.get("ok", false):
				_catalog_sync_in_flight = false
				_catalog_sync_time_left = CATALOG_RETRY_INTERVAL
				return
			var batch_body: Dictionary = batch_response.get("body", {})
			game_view.sim.ingest_catalog(
				batch_body.get("definitions", []) if batch_body.get("definitions", []) is Array else [],
				0
			)
		_content_refresh_time_left = CONTENT_REFRESH_INTERVAL
	var center_region: int = int(game_view.sim.player_catalog_region())
	var target_region: int = center_region
	var found_missing: bool = false
	var offsets: Array[int] = [0]
	for distance in range(1, CATALOG_PREFETCH_RADIUS + 1):
		offsets.append(-distance)
		offsets.append(distance)
	for offset in offsets:
		var candidate: int = center_region + offset
		if not game_view.sim.has_regional_catalog(candidate):
			target_region = candidate
			found_missing = true
			break
	if not found_missing:
		_catalog_sync_in_flight = false
		_catalog_sync_time_left = CATALOG_SYNC_INTERVAL
		return
	var response: Dictionary = await BackendClient.get_world_generation_region(
		game_view.sim.world_seed,
		target_region,
		game_view.sim.catalog_region_biomes(target_region)
	)
	if run_id != _catalog_sync_run_id or not _world_started or game_view.sim.world_id != expected_world_id:
		return
	_catalog_sync_in_flight = false
	if not response.get("ok", false):
		_catalog_sync_time_left = CATALOG_RETRY_INTERVAL
		return
	var body: Dictionary = response.get("body", {})
	if int(body.get("region_x", target_region)) != target_region:
		_catalog_sync_time_left = CATALOG_RETRY_INTERVAL
		return
	game_view.sim.ingest_regional_catalog(
		target_region,
		body.get("definitions", []) if body.get("definitions", []) is Array else [],
		body.get("structures", []) if body.get("structures", []) is Array else [],
		body.get("content_ids", []) if body.get("content_ids", []) is Array else [],
		body.get("structure_ids", []) if body.get("structure_ids", []) is Array else [],
		body.get("biomes", []) if body.get("biomes", []) is Array else [],
		body.get("biome_ids", []) if body.get("biome_ids", []) is Array else [],
		int(body.get("content_revision", 0)),
		int(body.get("structure_revision", 0)),
		int(body.get("biome_revision", 0))
	)
	_catalog_sync_time_left = 0.2
