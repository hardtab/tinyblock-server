extends RefCounted

const WorldSim = preload("res://gameplay/scripts/world.gd")
const Selector = preload("res://scripts/community_spawn_selector.gd")


static func run_tests() -> int:
	var failures := 0
	failures += _test_ruined_procedural_spawn_uses_intact_nearby_surface()
	failures += _test_finite_worlds_do_not_generate_land()
	failures += _test_allocation_counts_rotate_buckets()
	failures += _test_unsafe_and_crowded_surfaces_are_rejected()
	failures += _test_adjacent_hazards_are_buffered()
	failures += _test_hostile_clearance()
	failures += _test_canonical_modes_keep_existing_spawn()
	failures += _test_frontier_generates_at_most_one_chunk()
	failures += _test_allocated_frontier_stays_in_adaptive_search()
	failures += _test_stripped_flat_surface_does_not_meet_quality_floor()
	return failures


static func _test_ruined_procedural_spawn_uses_intact_nearby_surface() -> int:
	var sim := WorldSim.new()
	sim.create_procedural_world(77)
	for tx in range(-44, 45):
		var surface_y := int(sim.call("_terrain_surface_y", tx))
		for ty in range(surface_y - 3, surface_y + 5):
			sim.set_block(tx, ty, 0)
	var chunks_before := (sim.generated_chunks as Dictionary).size()
	var result := Selector.select_spawn(sim, {}, {})
	var stand_value: Variant = result.get("stand", Vector2i(Selector.NO_COORDINATE, Selector.NO_COORDINATE)) if not result.is_empty() else Vector2i(Selector.NO_COORDINATE, Selector.NO_COORDINATE)
	var stand: Vector2i = stand_value if stand_value is Vector2i else Vector2i(Selector.NO_COORDINATE, Selector.NO_COORDINATE)
	var ok := not result.is_empty() and absi(stand.x) >= 40 and _stand_is_supported_and_dry(sim, stand)
	ok = ok and (sim.generated_chunks as Dictionary).size() <= chunks_before + 1
	return _assert(ok, "a ruined procedural center selects safe intact ground nearby and stays within one chunk of generation")


static func _test_finite_worlds_do_not_generate_land() -> int:
	var skyblock := WorldSim.new()
	skyblock.create_island()
	var before_skyblock := (skyblock.tiles as Dictionary).size()
	var skyblock_result := Selector.select_spawn(skyblock, {}, {})
	var skyblock_unchanged := (skyblock.tiles as Dictionary).size() == before_skyblock
	var skyblock_safe := not skyblock_result.is_empty() and _stand_is_supported_and_dry(skyblock, skyblock_result.get("stand", Vector2i.ZERO))

	var islands := WorldSim.new()
	islands.create_floating_islands_world(917)
	var before_islands := (islands.tiles as Dictionary).size()
	var islands_result := Selector.select_spawn(islands, {}, {})
	var islands_unchanged := (islands.tiles as Dictionary).size() == before_islands
	var islands_safe := not islands_result.is_empty() and _stand_is_supported_and_dry(islands, islands_result.get("stand", Vector2i.ZERO))
	return _assert(
		skyblock_unchanged and skyblock_safe and islands_unchanged and islands_safe,
		"Skyblock and floating-island starts use existing dry ground without adding tiles"
	)


static func _test_allocation_counts_rotate_buckets() -> int:
	var sim := WorldSim.new()
	sim.create_island()
	for raw_pos in (sim.tiles as Dictionary).keys().duplicate():
		var pos: Vector2i = raw_pos
		sim.set_block(pos.x, pos.y, 0)
	sim.default_spawn = Vector2i(0, WorldSim.ISLAND_CY)
	for tx in range(-18, -13):
		sim.set_block(tx, WorldSim.ISLAND_CY, int(BlockDefs.BLOCKS.grass.id))
	for tx in range(14, 19):
		sim.set_block(tx, WorldSim.ISLAND_CY, int(BlockDefs.BLOCKS.grass.id))
	var first := Selector.select_spawn(sim, {}, {})
	if first.is_empty():
		return _assert(false, "allocation rotation fixture has a safe first candidate")
	var first_bucket := str(first.get("bucket", ""))
	var second := Selector.select_spawn(sim, {}, {first_bucket: 5})
	var rotated := not second.is_empty() and str(second.get("bucket", "")) != first_bucket
	return _assert(rotated, "a saturated allocation bucket rotates the next start to another viable patch")


static func _test_unsafe_and_crowded_surfaces_are_rejected() -> int:
	var sim := WorldSim.new()
	sim.create_island()
	for raw_pos in (sim.tiles as Dictionary).keys().duplicate():
		var pos: Vector2i = raw_pos
		sim.set_block(pos.x, pos.y, 0)
	sim.set_block(0, WorldSim.ISLAND_CY, int(BlockDefs.BLOCKS.lava.id))
	# This single tile has no walkable patch.
	sim.set_block(4, WorldSim.ISLAND_CY, int(BlockDefs.BLOCKS.grass.id))
	var unsafe_result := Selector.select_spawn(sim, {}, {})
	var no_safe_stand := unsafe_result.is_empty()
	if not no_safe_stand:
		return _assert(false, "fluid and isolated positions are not valid starts")

	var low_roof := WorldSim.new()
	low_roof.create_island()
	for raw_pos in (low_roof.tiles as Dictionary).keys().duplicate():
		var pos: Vector2i = raw_pos
		low_roof.set_block(pos.x, pos.y, 0)
	for tx in range(10, 17):
		low_roof.set_block(tx, WorldSim.ISLAND_CY, int(BlockDefs.BLOCKS.grass.id))
		low_roof.set_block(tx, WorldSim.ISLAND_CY - 2, int(BlockDefs.BLOCKS.stone.id))
	var blocked_surface_rejected := not Selector._basic_stand_is_safe(low_roof, Vector2i(13, WorldSim.ISLAND_CY))
	var roof_result := Selector.select_spawn(low_roof, {}, {})
	blocked_surface_rejected = blocked_surface_rejected and (
		roof_result.is_empty()
		or Vector2i(roof_result.get("stand", Vector2i.ZERO)) != Vector2i(13, WorldSim.ISLAND_CY)
	)
	if not blocked_surface_rejected:
		return _assert(false, "a low roof blocks the original surface stand")

	var crowded := WorldSim.new()
	crowded.create_island()
	for raw_pos in (crowded.tiles as Dictionary).keys().duplicate():
		var pos: Vector2i = raw_pos
		crowded.set_block(pos.x, pos.y, 0)
	for tx in range(11, 14):
		crowded.set_block(tx, WorldSim.ISLAND_CY, int(BlockDefs.BLOCKS.grass.id))
	var active_player := {
		"x": 12.0 * float(BlockDefs.TILE) + 6.0,
		"y": float(WorldSim.ISLAND_CY * BlockDefs.TILE) - 28.0,
		"w": 20.0,
		"h": 28.0,
		"health": WorldSim.MAX_PLAYER_HEALTH,
	}
	var crowded_result := Selector.select_spawn(crowded, {"active": active_player}, {})
	return _assert(crowded_result.is_empty(), "a narrow platform inside the active player's clearance is rejected")


static func _test_hostile_clearance() -> int:
	var sim := WorldSim.new()
	sim.create_island()
	for raw_pos in (sim.tiles as Dictionary).keys().duplicate():
		var pos: Vector2i = raw_pos
		sim.set_block(pos.x, pos.y, 0)
	for tx in range(10, 17):
		sim.set_block(tx, WorldSim.ISLAND_CY, int(BlockDefs.BLOCKS.grass.id))
	var hostile_name := str(BlockDefs.block_name_by_content_id.get("core.creature.dusk_prowler", "dusk_prowler"))
	sim.creatures["test_hostile"] = {
		"block_name": hostile_name,
		"x": 13.5,
		"y": float(WorldSim.ISLAND_CY) - 0.5,
		"health": 4,
		"dead": false,
	}
	var result := Selector.select_spawn(sim, {}, {})
	return _assert(result.is_empty(), "an aggressive creature near every candidate prevents a spawn there")


static func _test_adjacent_hazards_are_buffered() -> int:
	var sim := WorldSim.new()
	sim.create_island()
	for raw_pos in (sim.tiles as Dictionary).keys().duplicate():
		var pos: Vector2i = raw_pos
		sim.set_block(pos.x, pos.y, 0)
	for tx in range(10, 17):
		sim.set_block(tx, WorldSim.ISLAND_CY, int(BlockDefs.BLOCKS.grass.id))
	sim.set_block(9, WorldSim.ISLAND_CY, int(BlockDefs.BLOCKS.lava.id))
	var adjacent_is_unsafe := not Selector._hazard_buffer_is_safe(sim, Vector2i(10, WorldSim.ISLAND_CY))
	var next_tile_is_safe := Selector._hazard_buffer_is_safe(sim, Vector2i(11, WorldSim.ISLAND_CY))
	var result := Selector.select_spawn(sim, {}, {})
	var selected_away := not result.is_empty() and int((result.get("stand", Vector2i.ZERO) as Vector2i).x) > 10
	return _assert(
		adjacent_is_unsafe and next_tile_is_safe and selected_away,
		"the one-tile hazard buffer avoids a safe-looking spot immediately beside lava"
	)


static func _test_canonical_modes_keep_existing_spawn() -> int:
	var one_block := WorldSim.new()
	one_block.create_one_block_world(4)
	var one_block_before := (one_block.tiles as Dictionary).size()
	var one_block_result := Selector.select_spawn(one_block, {}, {})
	var one_block_unchanged := (one_block.tiles as Dictionary).size() == one_block_before

	var challenge := WorldSim.new()
	challenge.create_challenge_world(4)
	var challenge_before := (challenge.tiles as Dictionary).size()
	var challenge_result := Selector.select_spawn(challenge, {}, {})
	var challenge_unchanged := (challenge.tiles as Dictionary).size() == challenge_before
	return _assert(
		one_block_result.is_empty() and one_block_unchanged and challenge_result.is_empty() and challenge_unchanged,
		"One Block and Challenge retain their canonical starts and selector creates no replacement land"
	)


static func _test_frontier_generates_at_most_one_chunk() -> int:
	var sim := WorldSim.new()
	sim.create_procedural_world(12345)
	for raw_pos in (sim.tiles as Dictionary).keys().duplicate():
		var pos: Vector2i = raw_pos
		sim.set_block(pos.x, pos.y, 0)
	var before := (sim.generated_chunks as Dictionary).size()
	var result := Selector.select_spawn(sim, {}, {})
	var after := (sim.generated_chunks as Dictionary).size()
	var bounded := after <= before + 1
	var selected_safe := result.is_empty() or _stand_is_supported_and_dry(sim, result.get("stand", Vector2i.ZERO))
	var expanded := after == before + 1
	return _assert(bounded and selected_safe and expanded, "a depleted procedural area opens exactly one nearby frontier chunk and returns only a safe stand")


static func _test_allocated_frontier_stays_in_adaptive_search() -> int:
	var sim := WorldSim.new()
	sim.create_procedural_world(388)
	for chunk_x in range(-7, 10):
		sim.ensure_generated_chunk(chunk_x)
	sim.ensure_generated_chunk(12)
	for tx in range(192, 208):
		var surface_y := int(sim.call("_terrain_surface_y", tx))
		for ty in range(surface_y - 10, surface_y):
			sim.set_block(tx, ty, 0)
		sim.set_block(tx, surface_y, int(BlockDefs.BLOCKS.grass.id))
	for ty in range(1, 7):
		sim.set_block(192, int(sim.call("_terrain_surface_y", 192)) - ty, int(BlockDefs.BLOCKS.wood.id))
	var allocations: Dictionary = {}
	for bucket_x in range(-19, 20):
		for bucket_y in range(-20, 21):
			allocations["%d:%d" % [bucket_x, bucket_y]] = 6
	for bucket_y in range(-20, 21):
		allocations["24:%d" % bucket_y] = 1
		allocations["25:%d" % bucket_y] = 1
	var before := (sim.generated_chunks as Dictionary).size()
	var result := Selector.select_spawn(sim, {}, allocations)
	var stand_value: Variant = result.get("stand", Vector2i.ZERO)
	var selected_frontier: bool = false
	if stand_value is Vector2i:
		var stand: Vector2i = stand_value
		selected_frontier = stand.x >= 192 and stand.x < 224
	var unchanged_chunks := (sim.generated_chunks as Dictionary).size() == before
	return _assert(
		selected_frontier and unchanged_chunks,
		"a low-count selected frontier outside the default scan remains in view without opening another chunk"
	)


static func _test_stripped_flat_surface_does_not_meet_quality_floor() -> int:
	var sim := WorldSim.new()
	sim.create_procedural_world(944)
	for chunk_x in range(-8, 9):
		sim.ensure_generated_chunk(chunk_x)
	for tx in range(-128, 144):
		var surface_y := int(sim.call("_terrain_surface_y", tx))
		for ty in range(surface_y - 12, surface_y + 1):
			sim.set_block(tx, ty, 0)
		sim.set_block(tx, surface_y + 1, int(BlockDefs.BLOCKS.grass.id))
	var before := (sim.generated_chunks as Dictionary).size()
	var result := Selector.select_spawn(sim, {}, {})
	var after := (sim.generated_chunks as Dictionary).size()
	var reopened := after == before + 1 and str(result.get("reason", "")) == "procedural_frontier"
	var safe := not result.is_empty() and _stand_is_supported_and_dry(sim, result.get("stand", Vector2i.ZERO))
	return _assert(
		reopened and safe,
		"a bare floor dug one tile below the original surface is rated degraded and triggers at most one fresh safe chunk"
	)


static func _stand_is_supported_and_dry(sim: Object, raw_stand: Variant) -> bool:
	if not raw_stand is Vector2i:
		return false
	var stand: Vector2i = raw_stand
	var support: Dictionary = sim.call("get_block", stand.x, stand.y)
	if not bool(support.get("solid", false)) or bool(support.get("fluid", false)):
		return false
	for ty in range(stand.y - 2, stand.y):
		var above: Dictionary = sim.call("get_block", stand.x, ty)
		if bool(above.get("solid", false)) or bool(above.get("fluid", false)):
			return false
	return true


static func _assert(condition: bool, description: String) -> int:
	if condition:
		return 0
	push_error("Community spawn selector test failed: %s" % description)
	return 1
