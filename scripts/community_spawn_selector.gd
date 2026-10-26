extends RefCounted
class_name CommunitySpawnSelector

const WorldSim = preload("res://gameplay/scripts/world.gd")

const BUCKET_WIDTH := 8
const PROCEDURAL_EXISTING_RADIUS_CHUNKS := 8
const PROCEDURAL_FRONTIER_RADIUS_CHUNKS := 8
const MAX_ALLOCATION_FOCUS_CHUNKS := 4
const FINITE_SKYBLOCK_RADIUS_X := 32
const FINITE_SKYBLOCK_RADIUS_UP := 12
const FINITE_SKYBLOCK_RADIUS_DOWN := 16
const SURFACE_PATCH_RADIUS := 3
const MIN_PATCH_SUPPORTS := 3
const MIN_PATCH_RUN := 2
const MAX_PROCEDURAL_SURFACE_DROP := 2
const MAX_PROCEDURAL_SURFACE_RISE := 1
const MIN_PROCEDURAL_SURFACE_QUALITY := 70.0
const MIN_PROCEDURAL_NATURAL_COLUMNS := 4
const MIN_PROCEDURAL_RESOURCE_BLOCKS := 3
const HOSTILE_CLEARANCE_BLOCKS := 9.0
const FRONTIER_ALLOCATION_THRESHOLD := 6
const PLAYER_HARD_CLEARANCE_BLOCKS := 1.25
const PLAYER_CROWD_RADIUS_BLOCKS := 8.0
const NO_COORDINATE := 2147483647

const PLAYER_BUILT_BLOCK_NAMES := [
	"planks", "workbench", "furnace", "chest", "stone_bricks", "wooden_bricks",
	"crystal_bricks", "resonance_bricks", "shagot_scaffold",
]
const RESOURCE_BLOCK_NAMES := [
	"wood", "leaves", "pine_wood", "pine_needles", "palm_wood", "palm_leaves",
	"weeping_wood", "weeping_leaves", "charcoal", "copper_ore", "amethyst_crystal",
]


## Selects a safe per-player starting stand. `stand` is the supporting tile.
## The caller owns persistence of the returned bucket count and placement.
static func select_spawn(
	world: Object,
	active_players: Dictionary,
	allocations: Dictionary,
	preferred_anchor: Vector2i = Vector2i(NO_COORDINATE, NO_COORDINATE),
	maximum_distance_blocks: float = -1.0
) -> Dictionary:
	if world == null or not world.has_method("get_block"):
		return {}
	var mode := str(world.get("world_mode"))
	if mode in [WorldSim.WORLD_MODE_ONE_BLOCK, WorldSim.WORLD_MODE_CHALLENGE, WorldSim.WORLD_MODE_DUEL]:
		return {}
	var anchor := preferred_anchor
	if anchor.x == NO_COORDINATE or anchor.y == NO_COORDINATE:
		anchor = _selection_anchor(world, active_players, allocations)
	if mode == WorldSim.WORLD_MODE_PROCEDURAL:
		return _select_procedural(world, active_players, allocations, anchor, maximum_distance_blocks)
	if mode in [WorldSim.WORLD_MODE_SKYBLOCK, WorldSim.WORLD_MODE_FLOATING_ISLANDS]:
		return _select_finite(world, mode, active_players, allocations, anchor, maximum_distance_blocks)
	return {}


## Validates a stored supporting tile against current terrain, hazards and players.
static func is_spawn_safe(world: Object, stand: Vector2i, active_players: Dictionary) -> bool:
	if world == null:
		return false
	if not _candidate_is_safe(world, stand, active_players):
		return false
	var mode := str(world.get("world_mode"))
	var expected_name := _expected_surface_name(world, mode, stand.x, stand.y)
	return not _surface_profile(world, stand, stand.y, expected_name).is_empty()


static func _select_procedural(world: Object, active_players: Dictionary, allocations: Dictionary, anchor: Vector2i, maximum_distance_blocks: float = -1.0) -> Dictionary:
	if not world.has_method("_terrain_surface_y") or not world.has_method("ensure_generated_chunk"):
		return {}
	var anchor_chunk := floori(float(anchor.x) / float(WorldSim.CHUNK_WIDTH))
	var existing := _collect_procedural_candidates(
		world,
		anchor,
		active_players,
		allocations,
		anchor_chunk - PROCEDURAL_EXISTING_RADIUS_CHUNKS,
		anchor_chunk + PROCEDURAL_EXISTING_RADIUS_CHUNKS,
		-1
	)
	for focus_chunk in _allocation_focus_chunks(allocations, anchor_chunk):
		existing.append_array(_collect_procedural_candidates(
			world,
			anchor,
			active_players,
			allocations,
			focus_chunk,
			focus_chunk,
			focus_chunk
		))
	if maximum_distance_blocks > 0.0:
		existing = _filter_candidates_by_distance(existing, maximum_distance_blocks)
	var best_existing := _best_candidate(existing, anchor)
	var best_unallocated_quality := _best_candidate(
		_filter_candidates(existing, true, true),
		anchor
	)
	if not best_unallocated_quality.is_empty():
		return _public_result(best_unallocated_quality, "procedural_existing")
	if maximum_distance_blocks > 0.0:
		return _public_result(best_existing, "procedural_existing") if not best_existing.is_empty() else {}
	var should_expand := (
		best_existing.is_empty()
		or not _is_good_procedural_candidate(best_existing)
		or int(best_existing.get("allocation_count", 0)) >= FRONTIER_ALLOCATION_THRESHOLD
	)
	if not should_expand:
		return _public_result(best_existing, "procedural_existing")

	# Keep the search close to the current player cluster or allocation history.
	# Open one nearby frontier chunk only after local surface quality or capacity
	# has dropped enough that reusing the current field is no longer a good start.
	var frontier_chunk := _choose_frontier_chunk(world, anchor_chunk, allocations)
	if frontier_chunk != NO_COORDINATE and bool(world.call("ensure_generated_chunk", frontier_chunk)):
		var generated_candidates := _collect_procedural_candidates(
			world,
			anchor,
			active_players,
			allocations,
			frontier_chunk,
			frontier_chunk,
			frontier_chunk
		)
		var best_frontier := _best_candidate(generated_candidates, anchor)
		if not best_frontier.is_empty():
			var old_quality := float(best_existing.get("quality", -1.0))
			var old_allocation_count := int(best_existing.get("allocation_count", 0))
			var fresh_quality := float(best_frontier.get("quality", -1.0))
			var fresh_allocation_count := int(best_frontier.get("allocation_count", 0))
			if (
				best_existing.is_empty()
				or old_quality < MIN_PROCEDURAL_SURFACE_QUALITY
				or old_allocation_count >= FRONTIER_ALLOCATION_THRESHOLD
				or fresh_allocation_count < old_allocation_count
				or fresh_quality > old_quality
			):
				return _public_result(best_frontier, "procedural_frontier")

	if not best_existing.is_empty():
		return _public_result(best_existing, "procedural_existing")
	return {}


static func _collect_procedural_candidates(
	world: Object,
	anchor: Vector2i,
	active_players: Dictionary,
	allocations: Dictionary,
	first_chunk: int,
	last_chunk: int,
	only_chunk: int
) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	var generated_value: Variant = world.get("generated_chunks")
	if not generated_value is Dictionary:
		return candidates
	var generated: Dictionary = generated_value
	var chunk_first := mini(first_chunk, last_chunk)
	var chunk_last := maxi(first_chunk, last_chunk)
	for chunk_x in range(chunk_first, chunk_last + 1):
		if only_chunk >= 0 and chunk_x != only_chunk:
			continue
		if not generated.has(chunk_x) and not generated.has(str(chunk_x)):
			continue
		for tx in range(chunk_x * WorldSim.CHUNK_WIDTH, (chunk_x + 1) * WorldSim.CHUNK_WIDTH):
			var surface_y := int(world.call("_terrain_surface_y", tx))
			var expected_name := _expected_surface_name(world, WorldSim.WORLD_MODE_PROCEDURAL, tx, surface_y)
			_append_column_candidates(
				candidates,
				world,
				tx,
				surface_y,
				expected_name,
				MAX_PROCEDURAL_SURFACE_RISE,
				MAX_PROCEDURAL_SURFACE_DROP,
				anchor,
				active_players,
				allocations,
				"procedural"
			)
	return candidates


static func _select_finite(world: Object, mode: String, active_players: Dictionary, allocations: Dictionary, anchor: Vector2i, maximum_distance_blocks: float = -1.0) -> Dictionary:
	var candidates: Array[Dictionary] = []
	if mode == WorldSim.WORLD_MODE_SKYBLOCK:
		var first_x := anchor.x - FINITE_SKYBLOCK_RADIUS_X
		var last_x := anchor.x + FINITE_SKYBLOCK_RADIUS_X
		for tx in range(first_x, last_x + 1):
			var expected_name := _expected_surface_name(world, mode, tx, anchor.y)
			_append_column_candidates(
				candidates,
				world,
				tx,
				anchor.y,
				expected_name,
				FINITE_SKYBLOCK_RADIUS_UP,
				FINITE_SKYBLOCK_RADIUS_DOWN,
				anchor,
				active_players,
				allocations,
				"finite"
			)
	else:
		var layout_value: Variant = world.get("floating_island_layout")
		if not layout_value is Array:
			return {}
		for raw_island in layout_value:
			if not raw_island is Dictionary:
				continue
			var island: Dictionary = raw_island
			var center_value: Variant = island.get("center", Vector2i.ZERO)
			if not center_value is Vector2i:
				continue
			var center: Vector2i = center_value
			var half_width := clampi(int(island.get("half_width", 0)), 1, 16)
			var biome_id := str(island.get("biome", "plains"))
			var expected_name := _expected_surface_name(world, mode, center.x, center.y, biome_id)
			for tx in range(center.x - half_width, center.x + half_width + 1):
				_append_column_candidates(
					candidates,
					world,
					tx,
					center.y,
					expected_name,
					2,
					2,
					anchor,
					active_players,
					allocations,
					"finite"
				)
	if maximum_distance_blocks > 0.0:
		candidates = _filter_candidates_by_distance(candidates, maximum_distance_blocks)
	var best := _best_candidate(candidates, anchor)
	if best.is_empty():
		return {}
	return _public_result(best, "finite_island")


static func _filter_candidates_by_distance(candidates: Array[Dictionary], maximum_distance_blocks: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for candidate: Dictionary in candidates:
		if float(candidate.get("anchor_distance", INF)) <= maximum_distance_blocks:
			result.append(candidate)
	return result


static func _append_column_candidates(
	candidates: Array[Dictionary],
	world: Object,
	tx: int,
	reference_y: int,
	expected_name: String,
	maximum_rise: int,
	maximum_drop: int,
	anchor: Vector2i,
	active_players: Dictionary,
	allocations: Dictionary,
	search_kind: String
) -> void:
	for offset in _ordered_surface_offsets(maximum_rise, maximum_drop):
		var stand := Vector2i(tx, reference_y + offset)
		if not _basic_stand_is_safe(world, stand):
			continue
		var candidate := _score_candidate(
			world,
			stand,
			reference_y,
			expected_name,
			anchor,
			active_players,
			allocations
		)
		if candidate.is_empty():
			continue
		candidate["search_kind"] = search_kind
		candidates.append(candidate)


static func _score_candidate(
	world: Object,
	stand: Vector2i,
	reference_y: int,
	expected_name: String,
	anchor: Vector2i,
	active_players: Dictionary,
	allocations: Dictionary
) -> Dictionary:
	if not _candidate_is_safe(world, stand, active_players):
		return {}
	var profile := _surface_profile(world, stand, reference_y, expected_name)
	if profile.is_empty():
		return {}
	var crowding := _player_crowding_penalty(stand, active_players)
	var bucket := bucket_for_stand(stand)
	var allocation_count := maxi(0, int(allocations.get(bucket, 0)))
	var quality := float(profile.get("quality", 0.0))
	var allocation_penalty := minf(float(allocation_count) * 8.0, 32.0)
	return {
		"stand": stand,
		"bucket": bucket,
		"quality": quality,
		"natural": int(profile.get("natural", 0)),
		"resources": int(profile.get("resources", 0)),
		"score": quality - allocation_penalty - crowding,
		"allocation_count": allocation_count,
		"anchor_distance": Vector2(stand).distance_to(Vector2(anchor)),
	}


static func _surface_profile(world: Object, stand: Vector2i, reference_y: int, expected_name: String) -> Dictionary:
	var supported := 0
	var natural := 0
	var built := 0
	var current_run := 0
	var longest_run := 0
	var previous_y := NO_COORDINATE
	for dx in range(-SURFACE_PATCH_RADIUS, SURFACE_PATCH_RADIUS + 1):
		var tx := stand.x + dx
		var local_y := _nearby_surface_stand(world, tx, stand.y)
		if local_y == NO_COORDINATE:
			current_run = 0
			previous_y = NO_COORDINATE
			continue
		supported += 1
		var surface_block := _block_at(world, tx, local_y)
		if local_y == reference_y and str(surface_block.get("name", "")) == expected_name:
			natural += 1
		if _is_player_built_block(surface_block):
			built += 1
		if previous_y == NO_COORDINATE or absi(local_y - previous_y) <= 1:
			current_run += 1
		else:
			current_run = 1
		longest_run = maxi(longest_run, current_run)
		previous_y = local_y
	if supported < MIN_PATCH_SUPPORTS or longest_run < MIN_PATCH_RUN:
		return {}
	var resources := _nearby_resource_count(world, stand)
	var structures := _nearby_player_build_count(world, stand)
	built += structures
	var quality := 34.0
	quality += float(supported) * 2.0
	quality += float(mini(longest_run, 6)) * 2.5
	quality += float(natural) * 2.4
	quality += float(mini(resources, 6)) * 1.5
	quality -= minf(float(built) * 4.0, 32.0)
	return {
		"quality": clampf(quality, 0.0, 100.0),
		"supported": supported,
		"natural": natural,
		"resources": resources,
		"built": built,
	}


static func _candidate_is_safe(world: Object, stand: Vector2i, active_players: Dictionary) -> bool:
	if not _basic_stand_is_safe(world, stand):
		return false
	var player_value: Variant = world.get("player")
	var player: Dictionary = player_value if player_value is Dictionary else {}
	var player_w := maxf(1.0, float(player.get("w", 20.0)))
	var player_h := maxf(1.0, float(player.get("h", 28.0)))
	var player_x := float(stand.x * BlockDefs.TILE) + (float(BlockDefs.TILE) - player_w) * 0.5
	var player_y := float(stand.y * BlockDefs.TILE) - player_h
	if world.has_method("collides") and world.call("collides", player_x, player_y, player_w, player_h, false) != null:
		return false
	if not _body_area_is_safe(world, player_x, player_y, player_w, player_h):
		return false
	if not _hazard_buffer_is_safe(world, stand):
		return false
	if not _separated_from_players(stand, player_x, player_y, player_w, player_h, active_players):
		return false
	if _nearby_hostile(world, stand):
		return false
	return true


static func _basic_stand_is_safe(world: Object, stand: Vector2i) -> bool:
	var support := _block_at(world, stand.x, stand.y)
	if not bool(support.get("solid", false)) or bool(support.get("fluid", false)):
		return false
	if bool(support.get("falls_when_unsupported", false)) or _is_dangerous_block(support):
		return false
	var burning_value: Variant = world.get("burning_tiles")
	if burning_value is Dictionary and (burning_value as Dictionary).has(stand):
		return false
	for ty in range(stand.y - 2, stand.y):
		var above := _block_at(world, stand.x, ty)
		if bool(above.get("solid", false)) or bool(above.get("fluid", false)) or _is_dangerous_block(above):
			return false
		if burning_value is Dictionary and (burning_value as Dictionary).has(Vector2i(stand.x, ty)):
			return false
	return true


static func _hazard_buffer_is_safe(world: Object, stand: Vector2i) -> bool:
	var burning_value: Variant = world.get("burning_tiles")
	for tx in [stand.x - 1, stand.x + 1]:
		for ty in range(stand.y - 2, stand.y + 1):
			var adjacent := _block_at(world, tx, ty)
			if bool(adjacent.get("fluid", false)) or _is_dangerous_block(adjacent):
				return false
			if burning_value is Dictionary and (burning_value as Dictionary).has(Vector2i(tx, ty)):
				return false
	return true


static func _body_area_is_safe(world: Object, px: float, py: float, pw: float, ph: float) -> bool:
	var left := floori(px / float(BlockDefs.TILE))
	var right := floori((px + pw - 0.001) / float(BlockDefs.TILE))
	var top := floori(py / float(BlockDefs.TILE))
	var bottom := floori((py + ph - 0.001) / float(BlockDefs.TILE))
	for ty in range(top, bottom + 1):
		for tx in range(left, right + 1):
			var block := _block_at(world, tx, ty)
			if bool(block.get("fluid", false)) or _is_dangerous_block(block):
				return false
			var burning_value: Variant = world.get("burning_tiles")
			if burning_value is Dictionary and (burning_value as Dictionary).has(Vector2i(tx, ty)):
				return false
	return true


static func _separated_from_players(
	stand: Vector2i,
	player_x: float,
	player_y: float,
	player_w: float,
	player_h: float,
	active_players: Dictionary
) -> bool:
	var candidate_rect := Rect2(Vector2(player_x, player_y), Vector2(player_w, player_h))
	var center := Vector2(float(stand.x) + 0.5, float(stand.y) - 0.5)
	for raw_player_id in active_players:
		var raw_player: Variant = active_players[raw_player_id]
		if not raw_player is Dictionary:
			continue
		var active: Dictionary = raw_player
		if int(active.get("health", WorldSim.MAX_PLAYER_HEALTH)) <= 0:
			continue
		var x := float(active.get("x", 0.0))
		var y := float(active.get("y", 0.0))
		var w := maxf(1.0, float(active.get("w", player_w)))
		var h := maxf(1.0, float(active.get("h", player_h)))
		var active_rect := Rect2(Vector2(x, y), Vector2(w, h))
		if candidate_rect.intersects(active_rect):
			return false
		var active_center := Vector2((x + w * 0.5) / float(BlockDefs.TILE), (y + h * 0.5) / float(BlockDefs.TILE))
		if center.distance_to(active_center) < PLAYER_HARD_CLEARANCE_BLOCKS:
			return false
	return true


static func _player_crowding_penalty(stand: Vector2i, active_players: Dictionary) -> float:
	var penalty := 0.0
	var center := Vector2(float(stand.x) + 0.5, float(stand.y) - 0.5)
	for raw_player_id in active_players:
		var raw_player: Variant = active_players[raw_player_id]
		if not raw_player is Dictionary:
			continue
		var active: Dictionary = raw_player
		if int(active.get("health", WorldSim.MAX_PLAYER_HEALTH)) <= 0:
			continue
		var x := float(active.get("x", 0.0))
		var y := float(active.get("y", 0.0))
		var w := maxf(1.0, float(active.get("w", 20.0)))
		var h := maxf(1.0, float(active.get("h", 28.0)))
		var active_center := Vector2((x + w * 0.5) / float(BlockDefs.TILE), (y + h * 0.5) / float(BlockDefs.TILE))
		var distance := center.distance_to(active_center)
		if distance < PLAYER_CROWD_RADIUS_BLOCKS:
			penalty += PLAYER_CROWD_RADIUS_BLOCKS - distance
	return minf(penalty, 16.0)


static func _nearby_hostile(world: Object, stand: Vector2i) -> bool:
	var creatures_value: Variant = world.get("creatures")
	if not creatures_value is Dictionary or not world.has_method("_creature_definition"):
		return false
	var origin := Vector2(float(stand.x) + 0.5, float(stand.y) - 0.5)
	for raw_creature_id in (creatures_value as Dictionary):
		var raw_creature: Variant = (creatures_value as Dictionary)[raw_creature_id]
		if not raw_creature is Dictionary:
			continue
		var creature: Dictionary = raw_creature
		if bool(creature.get("dead", false)) or int(creature.get("health", 1)) <= 0:
			continue
		var definition_value: Variant = world.call("_creature_definition", str(creature.get("block_name", "")))
		if not definition_value is Dictionary:
			continue
		var definition: Dictionary = definition_value
		var behavior_value: Variant = definition.get("behavior", {})
		var behavior: Dictionary = behavior_value if behavior_value is Dictionary else {}
		if str(behavior.get("temperament", "passive")) != "aggressive":
			continue
		var position := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
		if origin.distance_to(position) < HOSTILE_CLEARANCE_BLOCKS:
			return true
	return false


static func _nearby_surface_stand(world: Object, tx: int, reference_y: int) -> int:
	for offset in [0, -1, 1, -2, 2]:
		var stand := Vector2i(tx, reference_y + int(offset))
		if _basic_stand_is_safe(world, stand):
			return stand.y
	return NO_COORDINATE


static func _ordered_surface_offsets(maximum_rise: int, maximum_drop: int) -> Array[int]:
	var offsets: Array[int] = [0]
	var radius := maxi(maximum_rise, maximum_drop)
	for distance in range(1, radius + 1):
		if distance <= maximum_rise:
			offsets.append(-distance)
		if distance <= maximum_drop:
			offsets.append(distance)
	return offsets


static func _expected_surface_name(world: Object, mode: String, tx: int, y: int, biome_hint: String = "") -> String:
	if mode == WorldSim.WORLD_MODE_SKYBLOCK:
		return "grass"
	var biome_id := biome_hint
	if biome_id.is_empty():
		if mode == WorldSim.WORLD_MODE_PROCEDURAL and world.has_method("_biome_at"):
			biome_id = str(world.call("_biome_at", tx))
			if world.has_method("_terrain_biome_for_position"):
				biome_id = str(world.call("_terrain_biome_for_position", tx, y, biome_id))
		else:
			biome_id = "plains"
	if world.has_method("_biome_terrain_block_name"):
		return str(world.call("_biome_terrain_block_name", biome_id, "surface_content_id", "grass"))
	return "grass"


static func _nearby_resource_count(world: Object, stand: Vector2i) -> int:
	var count := 0
	for dx in range(-5, 6):
		for dy in range(-10, 1):
			var block := _block_at(world, stand.x + dx, stand.y + dy)
			if _is_resource_block(block):
				count += 1
	return count


static func _nearby_player_build_count(world: Object, stand: Vector2i) -> int:
	var count := 0
	for dx in range(-4, 5):
		for dy in range(-3, 2):
			var block := _block_at(world, stand.x + dx, stand.y + dy)
			if _is_player_built_block(block):
				count += 1
	return count


static func _is_resource_block(block: Dictionary) -> bool:
	if str(block.get("name", "")) in RESOURCE_BLOCK_NAMES:
		return true
	var definition_value: Variant = block.get("definition", {})
	if not definition_value is Dictionary:
		return false
	var definition: Dictionary = definition_value
	var tags_value: Variant = definition.get("tags", [])
	if not tags_value is Array:
		return false
	for raw_tag in tags_value:
		if str(raw_tag) in ["tree", "wood", "leaves", "plant", "fiber"]:
			return true
	return false


static func _is_player_built_block(block: Dictionary) -> bool:
	if str(block.get("name", "")) in PLAYER_BUILT_BLOCK_NAMES:
		return true
	if bool(block.get("container", false)) or not str(block.get("station", "")).is_empty():
		return true
	var definition_value: Variant = block.get("definition", {})
	if not definition_value is Dictionary:
		return false
	var definition: Dictionary = definition_value
	var tags_value: Variant = definition.get("tags", [])
	if not tags_value is Array:
		return false
	for raw_tag in tags_value:
		if str(raw_tag) in ["crafted", "station", "container"]:
			return true
	return false


static func _is_dangerous_block(block: Dictionary) -> bool:
	if bool(block.get("hazardous", false)) or bool(block.get("dangerous", false)):
		return true
	var name := str(block.get("name", "")).to_lower()
	if name in ["lava", "fire", "burning_block"]:
		return true
	var definition_value: Variant = block.get("definition", {})
	if definition_value is Dictionary:
		var tags_value: Variant = (definition_value as Dictionary).get("tags", [])
		if tags_value is Array:
			for raw_tag in tags_value:
				if str(raw_tag).to_lower() in ["hazard", "hazardous", "hot", "lava"]:
					return true
	return false


static func _block_at(world: Object, tx: int, ty: int) -> Dictionary:
	var value: Variant = world.call("get_block", tx, ty)
	return value if value is Dictionary else {}


static func _selection_anchor(world: Object, active_players: Dictionary, allocations: Dictionary) -> Vector2i:
	var default_anchor := _default_spawn(world)
	var active_anchor := _active_player_cluster_anchor(active_players, default_anchor)
	if active_anchor != Vector2i(NO_COORDINATE, NO_COORDINATE):
		return active_anchor
	var allocated_anchor := _most_allocated_bucket_anchor(allocations, default_anchor)
	if allocated_anchor != Vector2i(NO_COORDINATE, NO_COORDINATE):
		return allocated_anchor
	return default_anchor


static func _active_player_cluster_anchor(active_players: Dictionary, fallback: Vector2i) -> Vector2i:
	var points: Array[Vector2i] = []
	for raw_player_id in active_players:
		var raw_player: Variant = active_players[raw_player_id]
		if not raw_player is Dictionary:
			continue
		var player: Dictionary = raw_player
		if int(player.get("health", WorldSim.MAX_PLAYER_HEALTH)) <= 0 or not player.has("x") or not player.has("y"):
			continue
		var width := maxf(1.0, float(player.get("w", 20.0)))
		var height := maxf(1.0, float(player.get("h", 28.0)))
		points.append(Vector2i(
			floori((float(player["x"]) + width * 0.5) / float(BlockDefs.TILE)),
			floori((float(player["y"]) + height) / float(BlockDefs.TILE)),
		))
	if points.is_empty():
		return Vector2i(NO_COORDINATE, NO_COORDINATE)
	var best := points[0]
	var best_neighbors := -1
	var best_distance := INF
	for point in points:
		var neighbors := 0
		for other in points:
			if Vector2(point).distance_to(Vector2(other)) <= 24.0:
				neighbors += 1
		var distance := Vector2(point).distance_to(Vector2(fallback))
		if neighbors > best_neighbors or (neighbors == best_neighbors and distance < best_distance):
			best = point
			best_neighbors = neighbors
			best_distance = distance
	return best


static func _most_allocated_bucket_anchor(allocations: Dictionary, fallback: Vector2i) -> Vector2i:
	var best := Vector2i(NO_COORDINATE, NO_COORDINATE)
	var best_count := 0
	var best_distance := INF
	for raw_bucket in allocations:
		var count := maxi(0, int(allocations[raw_bucket]))
		if count <= 0:
			continue
		var parts := str(raw_bucket).split(":")
		if parts.size() != 2:
			continue
		var bucket_x := int(parts[0])
		var bucket_y := int(parts[1])
		var center := Vector2i(bucket_x * BUCKET_WIDTH + BUCKET_WIDTH / 2, bucket_y * BUCKET_WIDTH + BUCKET_WIDTH / 2)
		var distance := Vector2(center).distance_to(Vector2(fallback))
		if count > best_count or (count == best_count and distance < best_distance):
			best = center
			best_count = count
			best_distance = distance
	return best


static func _default_spawn(world: Object) -> Vector2i:
	var value: Variant = world.get("default_spawn")
	return value if value is Vector2i else Vector2i.ZERO


static func _allocation_focus_chunks(allocations: Dictionary, anchor_chunk: int) -> Array[int]:
	var first_local_chunk := anchor_chunk - PROCEDURAL_EXISTING_RADIUS_CHUNKS
	var last_local_chunk := anchor_chunk + PROCEDURAL_EXISTING_RADIUS_CHUNKS
	var counts_by_chunk: Dictionary = {}
	for raw_bucket in allocations:
		var count := maxi(0, int(allocations[raw_bucket]))
		if count <= 0:
			continue
		var parts := str(raw_bucket).split(":")
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		var bucket_x := int(parts[0])
		var chunk_x := floori(float(bucket_x * BUCKET_WIDTH) / float(WorldSim.CHUNK_WIDTH))
		if chunk_x >= first_local_chunk and chunk_x <= last_local_chunk:
			continue
		var previous_count := int(counts_by_chunk.get(chunk_x, count))
		counts_by_chunk[chunk_x] = mini(previous_count, count)
	var chunks: Array[int] = []
	for raw_chunk in counts_by_chunk:
		chunks.append(int(raw_chunk))
	chunks.sort_custom(func(a: int, b: int) -> bool:
		var a_count := int(counts_by_chunk[a])
		var b_count := int(counts_by_chunk[b])
		if a_count != b_count:
			return a_count < b_count
		var a_distance := absi(a - anchor_chunk)
		var b_distance := absi(b - anchor_chunk)
		if a_distance != b_distance:
			return a_distance < b_distance
		return a < b
	)
	if chunks.size() > MAX_ALLOCATION_FOCUS_CHUNKS:
		chunks.resize(MAX_ALLOCATION_FOCUS_CHUNKS)
	return chunks


static func _choose_frontier_chunk(world: Object, anchor_chunk: int, allocations: Dictionary) -> int:
	var generated_value: Variant = world.get("generated_chunks")
	if not generated_value is Dictionary:
		return NO_COORDINATE
	var generated: Dictionary = generated_value
	var best_chunk := NO_COORDINATE
	var best_cost := INF
	var max_chunk := floori(float(WorldSim.COORD_LIMIT) / float(WorldSim.CHUNK_WIDTH))
	for distance in range(1, PROCEDURAL_FRONTIER_RADIUS_CHUNKS + 1):
		for direction in [-1, 1]:
			var chunk_x := anchor_chunk + int(direction) * distance
			if absi(chunk_x) > max_chunk or generated.has(chunk_x) or generated.has(str(chunk_x)):
				continue
			if not _frontier_chunk_has_surface(world, chunk_x):
				continue
			var minimum_allocation_count := _frontier_chunk_minimum_allocation_count(world, chunk_x, allocations)
			var cost := float(distance) * 5.0 + float(minimum_allocation_count) * 22.0
			if cost < best_cost or (is_equal_approx(cost, best_cost) and chunk_x < best_chunk):
				best_chunk = chunk_x
				best_cost = cost
	if best_chunk != NO_COORDINATE:
		return best_chunk
	for focus_chunk in _allocation_focus_chunks(allocations, anchor_chunk):
		for direction in [-1, 1]:
			var chunk_x := focus_chunk + int(direction)
			if absi(chunk_x) > max_chunk or generated.has(chunk_x) or generated.has(str(chunk_x)):
				continue
			if not _frontier_chunk_has_surface(world, chunk_x):
				continue
			var minimum_allocation_count := _frontier_chunk_minimum_allocation_count(world, chunk_x, allocations)
			var distance := absi(chunk_x - anchor_chunk)
			var cost := float(distance) * 5.0 + float(minimum_allocation_count) * 22.0
			if cost < best_cost or (is_equal_approx(cost, best_cost) and chunk_x < best_chunk):
				best_chunk = chunk_x
				best_cost = cost
	for direction in [-1, 1]:
		var chunk_x := _nearest_un_generated_chunk(
			generated,
			anchor_chunk,
			int(direction),
			PROCEDURAL_FRONTIER_RADIUS_CHUNKS + 1,
			max_chunk
		)
		if chunk_x == NO_COORDINATE or not _frontier_chunk_has_surface(world, chunk_x):
			continue
		var minimum_allocation_count := _frontier_chunk_minimum_allocation_count(world, chunk_x, allocations)
		var distance := absi(chunk_x - anchor_chunk)
		var cost := float(distance) * 5.0 + float(minimum_allocation_count) * 22.0
		if cost < best_cost or (is_equal_approx(cost, best_cost) and chunk_x < best_chunk):
			best_chunk = chunk_x
			best_cost = cost
	return best_chunk


static func _nearest_un_generated_chunk(
	generated: Dictionary,
	anchor_chunk: int,
	direction: int,
	first_distance: int,
	max_chunk: int
) -> int:
	var boundary_chunk := max_chunk * direction
	var max_distance := absi(boundary_chunk - anchor_chunk)
	if first_distance > max_distance:
		return NO_COORDINATE
	var low_distance := first_distance - 1
	var high_distance := first_distance
	while high_distance <= max_distance:
		var chunk_x := anchor_chunk + direction * high_distance
		if not generated.has(chunk_x) and not generated.has(str(chunk_x)):
			break
		low_distance = high_distance
		if high_distance == max_distance:
			return NO_COORDINATE
		high_distance = mini(high_distance * 2, max_distance)
	while high_distance - low_distance > 1:
		var middle_distance := floori(float(low_distance + high_distance) / 2.0)
		var chunk_x := anchor_chunk + direction * middle_distance
		if generated.has(chunk_x) or generated.has(str(chunk_x)):
			low_distance = middle_distance
		else:
			high_distance = middle_distance
	return anchor_chunk + direction * high_distance


static func _frontier_chunk_has_surface(world: Object, chunk_x: int) -> bool:
	var viable_columns := 0
	for tx in range(chunk_x * WorldSim.CHUNK_WIDTH, (chunk_x + 1) * WorldSim.CHUNK_WIDTH):
		var surface_y := int(world.call("_terrain_surface_y", tx))
		if world.has_method("_river_depth_at") and int(world.call("_river_depth_at", tx)) > 0:
			continue
		var expected_name := _expected_surface_name(world, WorldSim.WORLD_MODE_PROCEDURAL, tx, surface_y)
		if expected_name.is_empty() or expected_name in ["water", "lava"]:
			continue
		viable_columns += 1
	return viable_columns >= MIN_PATCH_SUPPORTS


static func _frontier_chunk_minimum_allocation_count(world: Object, chunk_x: int, allocations: Dictionary) -> int:
	var minimum := 2147483647
	for tx in range(chunk_x * WorldSim.CHUNK_WIDTH, (chunk_x + 1) * WorldSim.CHUNK_WIDTH):
		var surface_y := int(world.call("_terrain_surface_y", tx))
		var bucket := bucket_for_stand(Vector2i(tx, surface_y))
		minimum = mini(minimum, maxi(0, int(allocations.get(bucket, 0))))
	return minimum if minimum < 2147483647 else 0


static func _filter_candidates(candidates: Array[Dictionary], require_unallocated: bool, require_good_quality: bool) -> Array[Dictionary]:
	var filtered: Array[Dictionary] = []
	for candidate in candidates:
		if require_unallocated and int(candidate.get("allocation_count", 0)) > 0:
			continue
		if require_good_quality and not _is_good_procedural_candidate(candidate):
			continue
		filtered.append(candidate)
	return filtered


static func _is_good_procedural_candidate(candidate: Dictionary) -> bool:
	if float(candidate.get("quality", 0.0)) < MIN_PROCEDURAL_SURFACE_QUALITY:
		return false
	return (
		int(candidate.get("natural", 0)) >= MIN_PROCEDURAL_NATURAL_COLUMNS
		or int(candidate.get("resources", 0)) >= MIN_PROCEDURAL_RESOURCE_BLOCKS
	)


static func _best_candidate(candidates: Array[Dictionary], anchor: Vector2i) -> Dictionary:
	var best: Dictionary = {}
	for candidate in candidates:
		if best.is_empty() or _candidate_is_better(candidate, best, anchor):
			best = candidate
	return best


static func _candidate_is_better(candidate: Dictionary, current: Dictionary, anchor: Vector2i) -> bool:
	var candidate_score := float(candidate.get("score", -INF))
	var current_score := float(current.get("score", -INF))
	if candidate_score > current_score + 0.0001:
		return true
	if candidate_score < current_score - 0.0001:
		return false
	var candidate_quality := float(candidate.get("quality", -INF))
	var current_quality := float(current.get("quality", -INF))
	if candidate_quality > current_quality + 0.0001:
		return true
	if candidate_quality < current_quality - 0.0001:
		return false
	var candidate_allocations := int(candidate.get("allocation_count", 0))
	var current_allocations := int(current.get("allocation_count", 0))
	if candidate_allocations != current_allocations:
		return candidate_allocations < current_allocations
	var candidate_stand: Vector2i = candidate.get("stand", Vector2i.ZERO)
	var current_stand: Vector2i = current.get("stand", Vector2i.ZERO)
	var candidate_distance := Vector2(candidate_stand).distance_to(Vector2(anchor))
	var current_distance := Vector2(current_stand).distance_to(Vector2(anchor))
	if not is_equal_approx(candidate_distance, current_distance):
		return candidate_distance < current_distance
	if candidate_stand.x != current_stand.x:
		return candidate_stand.x < current_stand.x
	return candidate_stand.y < current_stand.y


static func _public_result(candidate: Dictionary, reason: String) -> Dictionary:
	if candidate.is_empty():
		return {}
	return {
		"stand": candidate.get("stand", Vector2i.ZERO),
		"bucket": str(candidate.get("bucket", "")),
		"score": float(candidate.get("score", 0.0)),
		"reason": reason,
	}


static func bucket_for_stand(stand: Vector2i) -> String:
	return "%d:%d" % [floori(float(stand.x) / float(BUCKET_WIDTH)), floori(float(stand.y) / float(BUCKET_WIDTH))]
