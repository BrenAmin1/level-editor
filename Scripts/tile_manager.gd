class_name TileManager extends RefCounted

# References to parent TileMap3D data and components
var tiles: Dictionary  # Reference to TileMap3D.tiles
var tile_meshes: Dictionary  # Reference to TileMap3D.tile_meshes
var custom_meshes: Dictionary  # Reference to TileMap3D.custom_meshes
var grid_size: float  # Reference to TileMap3D.grid_size
var parent_node: Node3D  # Reference to TileMap3D.parent_node
var tile_map: TileMap3D  # Reference to parent for calling methods
var mesh_generator: MeshGenerator  # Reference to MeshGenerator component
var diagonal_selector: DiagonalTileSelector
var disable_caching_this_flush: bool = false
# Auto-detection control
var auto_tile_selection_enabled: bool = false  # DISABLED for manual placement only

# Batch mode optimization
var batch_mode: bool = false
var dirty_tiles: Dictionary = {}  # Tiles that need mesh updates

# TECHNIQUE 9: Threading
var worker_thread: Thread = null
var mesh_generation_queue: Array = []
var generated_meshes: Dictionary = {}
var generation_mutex: Mutex = null
var should_stop_thread: bool = false
var is_flushing: bool = false  # Prevent overlapping flushes
var flush_completed_callback: Callable  # Optional: called once when flush fully finishes

# MESH CACHING: Reuse identical meshes
var mesh_cache: Dictionary = {}
var cache_hits: int = 0
var cache_misses: int = 0

# ============================================================================
# SETUP
# ============================================================================

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, tile_meshes_ref: Dictionary, 
		   meshes_ref: Dictionary, grid_sz: float, parent: Node3D, generator: MeshGenerator):
	tile_map = tilemap
	tiles = tiles_ref
	tile_meshes = tile_meshes_ref
	custom_meshes = meshes_ref
	grid_size = grid_sz
	parent_node = parent
	mesh_generator = generator
	diagonal_selector = DiagonalTileSelector.new()

# ============================================================================
# BATCH MODE
# ============================================================================

func set_batch_mode(enabled: bool):
	batch_mode = enabled
	
	if not enabled and not dirty_tiles.is_empty():
		# Batch mode ending - update all dirty tiles at once
		# Note: flush_batch_updates() is async, but we can't await here
		# So we start it and let it run in the background
		_start_flush_async()


# Helper to start async flush without blocking
func _start_flush_async():
	flush_batch_updates()


func flush_batch_updates():
	if dirty_tiles.is_empty():
		return

	# If only a few tiles, don't use threading (likely edit mode)
	if dirty_tiles.size() < 25:
		_flush_without_threading()
		return

	# Prevent overlapping flush operations
	if is_flushing:
		print("Flush already in progress, skipping...")
		return

	is_flushing = true

	# Clean up any existing thread first
	if worker_thread != null:
		if worker_thread.is_alive():
			should_stop_thread = true
			worker_thread.wait_to_finish()
		worker_thread = null

	print("\n=== BATCH FLUSH START ===")
	print("Dirty tiles: ", dirty_tiles.size())

	# Collect all tiles that need updates (dirty + their neighbors)
	var tiles_to_update = {}
	for pos in dirty_tiles.keys():
		tiles_to_update[pos] = true
		for offset in [
			Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
			Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1),
			Vector3i(1, 0, 1), Vector3i(1, 0, -1),
			Vector3i(-1, 0, 1), Vector3i(-1, 0, -1)
		]:
			var neighbor_pos = pos + offset
			if neighbor_pos in tiles:
				tiles_to_update[neighbor_pos] = true
		if pos.y > 0:
			var below_pos = pos + Vector3i(0, -1, 0)
			if below_pos in tiles:
				tiles_to_update[below_pos] = true
				for cardinal_offset in [
					Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
					Vector3i(0, 0, 1), Vector3i(0, 0, -1)
				]:
					var affected_pos = below_pos + cardinal_offset
					if affected_pos in tiles:
						tiles_to_update[affected_pos] = true

	_flush_positions_size = tiles_to_update.size()
	print("Total tiles to update (including neighbors): ", _flush_positions_size)

	_flush_batch_size = 50
	if _flush_positions_size > 5000:
		_flush_batch_size = 20
	elif _flush_positions_size > 1000:
		_flush_batch_size = 30

	cache_hits = 0
	cache_misses = 0
	_flush_applied_count = 0
	_flush_start_time = Time.get_ticks_msec()
	_flush_last_progress_print = 0

	should_stop_thread = false
	if generation_mutex == null:
		generation_mutex = Mutex.new()
	mesh_generation_queue = []
	generated_meshes.clear()

	mesh_generation_queue = _prepare_mesh_generation_batch(tiles_to_update)

	worker_thread = Thread.new()
	var thread_error = worker_thread.start(_generate_meshes_threaded)
	if thread_error != OK:
		push_error("Failed to start worker thread: ", thread_error)
		worker_thread = null
		is_flushing = false
		return

	print("Worker thread started, tick() will apply meshes each frame")


# Per-frame state for the tick-driven flush
var _flush_positions_size: int = 0
var _flush_applied_count: int = 0
var _flush_batch_size: int = 50
var _flush_start_time: int = 0
var _flush_last_progress_print: int = 0


func tick():
	"""Drive the flush one frame at a time. Call every frame from level_editor._process.
	No coroutines, no awaits — safe to stop instantly via should_stop_thread."""
	if not is_flushing:
		return

	# Bail immediately on shutdown — caller sets should_stop_thread then calls tick()
	# one final time via cleanup(), which forces finalisation without blocking.
	if should_stop_thread:
		_finalise_flush(false)
		return

	generation_mutex.lock()
	var available_meshes = generated_meshes.keys()
	var thread_alive = worker_thread != null and worker_thread.is_alive()
	generation_mutex.unlock()

	# Acknowledge a finished thread
	if worker_thread != null and not thread_alive:
		worker_thread.wait_to_finish()
		worker_thread = null
		thread_alive = false

	# Apply a batch of completed meshes this frame
	var processed_this_frame = 0
	for pos in available_meshes:
		if processed_this_frame >= _flush_batch_size:
			break
		generation_mutex.lock()
		var mesh = generated_meshes.get(pos)
		if mesh:
			generated_meshes.erase(pos)
		generation_mutex.unlock()
		if mesh:
			_apply_mesh_to_scene(pos, mesh)
			_flush_applied_count += 1
			processed_this_frame += 1

	# Progress logging
	if _flush_positions_size > 100 and (_flush_applied_count - _flush_last_progress_print >= 500 or _flush_applied_count == _flush_positions_size):
		var elapsed = Time.get_ticks_msec() - _flush_start_time
		var rate = float(_flush_applied_count) / (elapsed / 1000.0) if elapsed > 0 else 0.0
		print("  Progress: ", _flush_applied_count, "/", _flush_positions_size, " (", int(rate), " tiles/sec)")
		_flush_last_progress_print = _flush_applied_count

	# Finalise when thread is done and no meshes remain, or all applied
	var done = _flush_applied_count >= _flush_positions_size
	var stalled = not thread_alive and available_meshes.is_empty()
	if done or stalled:
		_finalise_flush(done)


func _finalise_flush(completed_successfully: bool):
	_cleanup_worker_thread()

	if mesh_generator.culling_manager:
		mesh_generator.culling_manager.batch_mode_skip_culling = false

	if completed_successfully:
		var total_requests = cache_hits + cache_misses
		var hit_rate = (float(cache_hits) / total_requests * 100.0) if total_requests > 0 else 0.0
		print("Cache: ", cache_hits, " hits / ", cache_misses, " misses (", "%.1f" % hit_rate, "% hit rate)")
		var elapsed = Time.get_ticks_msec() - _flush_start_time
		print("✓ Flush complete in ", elapsed / 1000.0, " seconds")
	else:
		print("⚠ Flush interrupted")

	dirty_tiles.clear()
	print("=== BATCH FLUSH END ===\n")
	is_flushing = false

	# Fire the one-shot callback if set (used e.g. to re-apply rotations after load)
	if flush_completed_callback.is_valid():
		var cb = flush_completed_callback
		flush_completed_callback = Callable()  # Clear before calling to avoid re-entrancy
		cb.call()




func _prepare_mesh_generation_batch(tiles_to_update: Dictionary) -> Array:
	var mesh_gen_queue = []
	
	print("Capturing tile data with neighbors...")
	print("DEBUG: tiles_to_update size: ", tiles_to_update.size())
	print("DEBUG: Total tiles in scene: ", tiles.size())
	
	# Count tiles at each Y level for debugging
	var tiles_by_y = {}
	for tile_pos in tiles.keys():
		if tile_pos.y not in tiles_by_y:
			tiles_by_y[tile_pos.y] = 0
		tiles_by_y[tile_pos.y] += 1
	print("DEBUG: Tiles by Y-level: ", tiles_by_y)
	
	for pos in tiles_to_update.keys():
		if pos not in tiles:
			continue
		
		var tile_type = tiles[pos]
		var rotation = tile_map.tile_rotations.get(pos, 0.0)
		var neighbors = get_neighbors(pos)  # Capture neighbors NOW while all tiles exist
		
		# CRITICAL: Also capture if this is a fully enclosed tile
		var is_fully_enclosed = _check_if_fully_enclosed(pos, neighbors)
		
		# DEBUG: Print enclosed status for tiles at y=0
		if pos.y == 0 and is_fully_enclosed:
			print("DEBUG: Tile at ", pos, " is FULLY ENCLOSED!")
		
		mesh_gen_queue.append({
			"pos": pos,
			"tile_type": tile_type,
			"rotation": rotation,
			"neighbors": neighbors,  # Pre-captured with all diagonals
			"is_fully_enclosed": is_fully_enclosed  # Pre-captured enclosed status
		})
	
	return mesh_gen_queue


# Check if a tile is fully enclosed (has tile above and all neighbors have tiles above)
func _check_if_fully_enclosed(pos: Vector3i, neighbors: Dictionary) -> bool:
	var NeighborDir = MeshGenerator.NeighborDir
	
	# Must have a tile above
	if neighbors[NeighborDir.UP] == -1:
		return false
	
	# Must have all 4 cardinal neighbors
	if neighbors[NeighborDir.NORTH] == -1 or \
	   neighbors[NeighborDir.SOUTH] == -1 or \
	   neighbors[NeighborDir.EAST] == -1 or \
	   neighbors[NeighborDir.WEST] == -1:
		return false
	
	# Check if all cardinal neighbors also have tiles above them
	var north_pos = pos + Vector3i(0, 0, -1)
	var south_pos = pos + Vector3i(0, 0, 1)
	var east_pos = pos + Vector3i(1, 0, 0)
	var west_pos = pos + Vector3i(-1, 0, 0)
	
	var north_has_above = (north_pos + Vector3i(0, 1, 0)) in tiles
	var south_has_above = (south_pos + Vector3i(0, 1, 0)) in tiles
	var east_has_above = (east_pos + Vector3i(0, 1, 0)) in tiles
	var west_has_above = (west_pos + Vector3i(0, 1, 0)) in tiles
	
	return north_has_above and south_has_above and east_has_above and west_has_above


func _check_if_only_top_exposed(neighbors: Dictionary) -> bool:
	var NeighborDir = MeshGenerator.NeighborDir
	# No tile above
	if neighbors[NeighborDir.UP] != -1:
		return false
	# All 4 cardinal sides must be filled
	if neighbors[NeighborDir.NORTH] == -1 or \
	   neighbors[NeighborDir.SOUTH] == -1 or \
	   neighbors[NeighborDir.EAST] == -1 or \
	   neighbors[NeighborDir.WEST] == -1:
		return false
	# All 4 diagonal corners must also be filled — if any diagonal is missing
	# this is an inner corner tile and the bulge mesh should be kept
	if neighbors[NeighborDir.DIAGONAL_NW] == -1 or \
	   neighbors[NeighborDir.DIAGONAL_NE] == -1 or \
	   neighbors[NeighborDir.DIAGONAL_SW] == -1 or \
	   neighbors[NeighborDir.DIAGONAL_SE] == -1:
		return false
	return true


# Helper function to ensure thread is always cleaned up properly
func _cleanup_worker_thread():
	should_stop_thread = true
	
	if worker_thread != null:
		# Only call wait_to_finish if thread is still alive
		# (if it's not alive but we didn't call wait_to_finish yet, we still need to call it)
		if worker_thread.is_alive():
			worker_thread.wait_to_finish()
		# If thread is not alive, it might have already been waited on in the main loop
		# Set to null regardless
		worker_thread = null


# Worker thread function for mesh generation
func _generate_meshes_threaded():
	while not mesh_generation_queue.is_empty() and not should_stop_thread:
		var tile_data = mesh_generation_queue.pop_front()
		
		# Unpack pre-captured data
		var pos = tile_data["pos"]
		var tile_type = tile_data["tile_type"]
		var rotation = tile_data["rotation"]
		var neighbors = tile_data["neighbors"]  # Already has diagonals captured!
		var is_fully_enclosed = tile_data["is_fully_enclosed"]  # Pre-captured enclosed status
		
		# MESH CACHING: Create cache key
		var cache_key = _create_cache_key(tile_type, neighbors, rotation, is_fully_enclosed)
		
		var mesh: ArrayMesh
		
		# Check cache first
		if cache_key in mesh_cache:
			mesh = mesh_cache[cache_key]
			generation_mutex.lock()
			cache_hits += 1
			generation_mutex.unlock()
		else:
			# Generate mesh on background thread
			if tile_type in custom_meshes:
				mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation, is_fully_enclosed)
			else:
				mesh = mesh_generator.generate_tile_mesh(tile_type, neighbors)
			
			# Cache the generated mesh
			mesh_cache[cache_key] = mesh
			
			generation_mutex.lock()
			cache_misses += 1
			generation_mutex.unlock()
		
		# Store completed mesh (thread-safe)
		generation_mutex.lock()
		generated_meshes[pos] = mesh
		generation_mutex.unlock()


# MESH CACHING: Create unique cache key for mesh variations
func _create_cache_key(tile_type: int, neighbors: Dictionary, rotation: float, is_fully_enclosed: bool = false) -> String:
	# Hash: tile_type + 6 cardinal neighbors + 4 diagonal neighbors + rotation + is_fully_enclosed
	var rounded_rotation = round(rotation / 15.0) * 15.0
	var n = neighbors
	var enclosed_flag = 1 if is_fully_enclosed else 0
	return "%d_%d%d%d%d%d%d_%d%d%d%d_%.0f_%d" % [
		tile_type,
		n[MeshGenerator.NeighborDir.NORTH],
		n[MeshGenerator.NeighborDir.SOUTH],
		n[MeshGenerator.NeighborDir.EAST],
		n[MeshGenerator.NeighborDir.WEST],
		n[MeshGenerator.NeighborDir.UP],
		n[MeshGenerator.NeighborDir.DOWN],
		n.get(MeshGenerator.NeighborDir.DIAGONAL_NW, -1),
		n.get(MeshGenerator.NeighborDir.DIAGONAL_NE, -1),
		n.get(MeshGenerator.NeighborDir.DIAGONAL_SW, -1),
		n.get(MeshGenerator.NeighborDir.DIAGONAL_SE, -1),
		rounded_rotation,
		enclosed_flag  # Add this to the cache key
	]


# Apply pre-generated mesh to scene (main thread only)
func _apply_mesh_to_scene(pos: Vector3i, mesh: ArrayMesh):
	if not parent_node:
		return
	
	if pos not in tiles:
		return
	
	var rotation = tile_map.tile_rotations.get(pos, 0.0)
	var world_pos = grid_to_world(pos)
	
	# Stairs bake rotation into vertices — don't also rotate the node
	var TILE_TYPE_STAIRS = 5
	var node_rotation = 0.0 if tiles[pos] == TILE_TYPE_STAIRS else rotation
	
	if pos in tile_meshes:
		# Update existing mesh instance
		tile_meshes[pos].mesh = mesh
		tile_meshes[pos].position = world_pos
		tile_meshes[pos].rotation_degrees.y = node_rotation
		if node_rotation != 0.0:
			_apply_rotation_center_offset(tile_meshes[pos])
	else:
		# Create new mesh instance
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.position = world_pos
		mesh_instance.rotation_degrees.y = node_rotation
		mesh_instance.process_priority = 1
		
		if node_rotation != 0.0:
			_apply_rotation_center_offset(mesh_instance)
		
		var static_body = StaticBody3D.new()
		var collision_shape = CollisionShape3D.new()
		var box_shape = BoxShape3D.new()
		box_shape.size = Vector3(grid_size, grid_size, grid_size)
		collision_shape.shape = box_shape
		collision_shape.position = Vector3(grid_size/2, grid_size/2, grid_size/2)
		static_body.add_child(collision_shape)
		mesh_instance.add_child(static_body)
		
		parent_node.add_child(mesh_instance)
		tile_meshes[pos] = mesh_instance
	
	# Apply stored material if exists
	if pos in tile_map.tile_materials:
		var material_index = tile_map.tile_materials[pos]
		if tile_map.material_palette_ref and tile_map.material_palette_ref.has_method("get_material_at_index"):
			var material = tile_map.material_palette_ref.get_material_at_index(material_index)
			if material and pos in tile_meshes:
				tile_meshes[pos].set_surface_override_material(0, material)


func mark_dirty(pos: Vector3i):
	if batch_mode:
		dirty_tiles[pos] = true
	else:
		_immediate_update_tile_mesh(pos)


# Clear cache (useful for memory management or when custom meshes change)
func clear_mesh_cache():
	mesh_cache.clear()
	print("Mesh cache cleared")

# ============================================================================
# COORDINATE CONVERSION
# ============================================================================

func world_to_grid(pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(pos.x / grid_size),
		floori(pos.y / grid_size),
		floori(pos.z / grid_size)
	)


func grid_to_world(pos: Vector3i) -> Vector3:
	var offset = tile_map.get_offset_for_y(pos.y)
	return Vector3(pos.x * grid_size + offset.x, pos.y * grid_size, pos.z * grid_size + offset.y)

# ============================================================================
# TILE MANIPULATION
# ============================================================================

func place_tile(pos: Vector3i, tile_type: int):
	tiles[pos] = tile_type
	
	# Store step count for stairs, and set default facing direction
	var TILE_TYPE_STAIRS = 5
	if tile_type == TILE_TYPE_STAIRS:
		if tile_map.parent_node and tile_map.parent_node.current_stair_steps:
			tile_map.tile_step_counts[pos] = tile_map.parent_node.current_stair_steps
		# Only set default rotation if no rotation is already assigned
		# (preserves rotation on repaint/replace operations)
		if pos not in tile_map.tile_rotations:
			tile_map.tile_rotations[pos] = 180.0  # South-facing by default
	
	if batch_mode:
		dirty_tiles[pos] = true
		# Neighbors will be marked in flush_batch_updates()
	else:
		# Normal mode: update immediately with smart neighbor updating
		update_tile_mesh(pos)
		
		# Update cardinal neighbors (always)
		for offset in [
			Vector3i(1,0,0), Vector3i(-1,0,0),
			Vector3i(0,1,0), Vector3i(0,-1,0),
			Vector3i(0,0,1), Vector3i(0,0,-1)
		]:
			var neighbor_pos = pos + offset
			if neighbor_pos in tiles:
				update_tile_mesh(neighbor_pos)
		
		# Diagonal neighbors: Only update if they're next to 2+ of this tile's cardinal neighbors
		for diag_offset in [
			Vector3i(1, 0, 1), Vector3i(1, 0, -1),
			Vector3i(-1, 0, 1), Vector3i(-1, 0, -1)
		]:
			var diag_pos = pos + diag_offset
			if diag_pos in tiles:
				# Check if this diagonal has 2+ cardinal connections to 'pos' through other tiles
				var shared_cardinals = 0
				
				# For diagonal (1,0,1), check (1,0,0) and (0,0,1)
				# For diagonal (1,0,-1), check (1,0,0) and (0,0,-1)
				# For diagonal (-1,0,1), check (-1,0,0) and (0,0,1)
				# For diagonal (-1,0,-1), check (-1,0,0) and (0,0,-1)
				var cardinal_a = Vector3i(diag_offset.x, 0, 0)  # X neighbor
				var cardinal_b = Vector3i(0, 0, diag_offset.z)  # Z neighbor
				
				if (pos + cardinal_a) in tiles:
					shared_cardinals += 1
				if (pos + cardinal_b) in tiles:
					shared_cardinals += 1
				
				# Only update diagonal if it has 2 shared cardinals (forms a corner)
				if shared_cardinals >= 2:
					update_tile_mesh(diag_pos)
		
		# SPECIAL: If placing on top of another tile, check if any of the lower tile's
		# CARDINAL neighbors need re-evaluation (for bulge culling)
		var tiles_to_update = []  # DECLARE HERE AT PROPER SCOPE
		if pos.y > 0:
			var below_pos = pos + Vector3i(0, -1, 0)
			if below_pos in tiles:
				# Collect all affected tiles first
				tiles_to_update.append(below_pos)
				
				# Add cardinal neighbors of the tile below
				for cardinal_offset in [
					Vector3i(1, 0, 0),   # East of below
					Vector3i(-1, 0, 0),  # West of below
					Vector3i(0, 0, 1),   # South of below
					Vector3i(0, 0, -1)   # North of below
				]:
					var affected_pos = below_pos + cardinal_offset
					if affected_pos in tiles:
						if affected_pos not in tiles_to_update:
							tiles_to_update.append(affected_pos)
		
		# TWO-PASS UPDATE: Update all collected tiles
		# This ensures all neighbor data is fresh before checking "fully enclosed" status
		for update_pos in tiles_to_update:
			update_tile_mesh(update_pos)
		
		# SECOND PASS: Re-update tiles that might have had their "fully enclosed" status change
		# This is needed because the first pass updated meshes, but some tiles' enclosed status
		# depends on their neighbors having fresh data
		if pos.y > 0:
			var below_pos = pos + Vector3i(0, -1, 0)
			if below_pos in tiles:
				# Re-update cardinal neighbors of the tile below
				for cardinal_offset in [
					Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
					Vector3i(0, 0, 1), Vector3i(0, 0, -1)
				]:
					var affected_pos = below_pos + cardinal_offset
					if affected_pos in tiles:
						update_tile_mesh(affected_pos)


func remove_tile(pos: Vector3i):
	if pos not in tiles:
		return
	
	tiles.erase(pos)
	
	# Clean up rotation data
	if pos in tile_map.tile_rotations:
		tile_map.tile_rotations.erase(pos)
	
	# Clean up step count data
	if pos in tile_map.tile_step_counts:
		tile_map.tile_step_counts.erase(pos)
	
	if pos in tile_meshes:
		tile_meshes[pos].queue_free()
		tile_meshes.erase(pos)
	
	if batch_mode:
		# In batch mode, neighbors will be updated in flush_batch_updates()
		# Just mark this position (even though tile is removed, neighbors need to know)
		dirty_tiles[pos] = true
	else:
		# Normal mode: immediate neighbor updates
		for offset in [
			Vector3i(1,0,0), Vector3i(-1,0,0),
			Vector3i(0,1,0), Vector3i(0,-1,0),
			Vector3i(0,0,1), Vector3i(0,0,-1),
			Vector3i(1, 0, 1), Vector3i(1, 0, -1),
			Vector3i(-1, 0, 1), Vector3i(-1, 0, -1)
		]:
			var neighbor_pos = pos + offset
			if neighbor_pos in tiles:
				update_tile_mesh(neighbor_pos)


func has_tile(pos: Vector3i) -> bool:
	return pos in tiles


func get_tile_type(pos: Vector3i) -> int:
	return tiles.get(pos, -1)

# ============================================================================
# MESH MANAGEMENT
# ============================================================================

func update_tile_mesh(pos: Vector3i):
	if batch_mode:
		mark_dirty(pos)
	else:
		_immediate_update_tile_mesh(pos)


func _immediate_update_tile_mesh(pos: Vector3i):
	if not parent_node:
		return
	
	if pos not in tiles:
		return
	
	var tile_type = tiles[pos]
	
	# Get rotation if exists
	var rotation = 0.0
	if pos in tile_map.tile_rotations:
		rotation = tile_map.tile_rotations[pos]
	
	# Get step count if this is stairs
	var step_count = 4  # Default
	var TILE_TYPE_STAIRS = 5
	if tile_type == TILE_TYPE_STAIRS and pos in tile_map.tile_step_counts:
		step_count = tile_map.tile_step_counts[pos]
	
	# Use custom mesh if available, otherwise generate default.
	# Stairs (TILE_TYPE_STAIRS) are procedural and must also go through the
	# rotation-aware path even though they have no entry in custom_meshes.
	var mesh: ArrayMesh
	var neighbors = get_neighbors(pos)
	if tile_type in custom_meshes or tile_type == TILE_TYPE_STAIRS:
		var is_fully_enclosed = _check_if_fully_enclosed(pos, neighbors)
		var is_only_top_exposed = _check_if_only_top_exposed(neighbors)
		mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation, is_fully_enclosed, step_count, is_only_top_exposed)
	else:
		mesh = mesh_generator.generate_tile_mesh(tile_type, neighbors)
	
	# Position at corner of grid cell
	var world_pos = grid_to_world(pos)
	
	# Stairs bake rotation into vertices, so the node must NOT be rotated too.
	# All other tile types keep geometry unrotated and rely on node rotation.
	# (TILE_TYPE_STAIRS already declared above)
	var node_rotation = 0.0 if tile_type == TILE_TYPE_STAIRS else rotation
	
	if pos in tile_meshes:
		tile_meshes[pos].mesh = mesh
		tile_meshes[pos].position = world_pos
		tile_meshes[pos].rotation_degrees.y = node_rotation
		# Apply center offset when rotating
		if node_rotation != 0.0:
			_apply_rotation_center_offset(tile_meshes[pos])
	else:
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.position = world_pos
		mesh_instance.rotation_degrees.y = node_rotation
		mesh_instance.process_priority = 1
		
		# Apply center offset when rotating
		if node_rotation != 0.0:
			_apply_rotation_center_offset(mesh_instance)
		
		var static_body = StaticBody3D.new()
		var collision_shape = CollisionShape3D.new()
		var box_shape = BoxShape3D.new()
		box_shape.size = Vector3(grid_size, grid_size, grid_size)
		collision_shape.shape = box_shape
		collision_shape.position = Vector3(grid_size/2, grid_size/2, grid_size/2)
		
		static_body.add_child(collision_shape)
		mesh_instance.add_child(static_body)
		
		tile_meshes[pos] = mesh_instance
		parent_node.add_child(mesh_instance)
	
	# Apply stored material if exists (in _immediate_update_tile_mesh)
	if pos in tile_map.tile_materials:
		var material_index = tile_map.tile_materials[pos]
		if tile_map.material_palette_ref and tile_map.material_palette_ref.has_method("get_material_at_index"):
			var material = tile_map.material_palette_ref.get_material_at_index(material_index)
			if material and pos in tile_meshes:
				tile_meshes[pos].set_surface_override_material(0, material)

# ============================================================================
# Regenerate tile with rotation
# ============================================================================

func regenerate_tile_with_rotation(pos: Vector3i, rotation_degrees: float):
	"""Regenerate a single tile's mesh with specified rotation"""
	if pos not in tiles:
		return
	
	if not parent_node:
		return
	
	# Generate new mesh WITH ROTATION
	var tile_type = tiles[pos]
	var neighbors = get_neighbors(pos)
	var is_fully_enclosed = _check_if_fully_enclosed(pos, neighbors)
	
	var mesh: ArrayMesh
	if tile_type in custom_meshes:
		# PASS ROTATION AND is_fully_enclosed to mesh generator
		mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation_degrees, is_fully_enclosed)
	else:
		mesh = mesh_generator.generate_tile_mesh(tile_type, neighbors)
	
	# Position at corner of grid cell
	var world_pos = grid_to_world(pos)
	
	# Stairs bake rotation into vertices — don't also rotate the node
	var TILE_TYPE_STAIRS = 5
	var node_rotation = 0.0 if tile_type == TILE_TYPE_STAIRS else rotation_degrees
	
	# Update existing mesh instance or create new one
	if pos in tile_meshes:
		tile_meshes[pos].mesh = mesh
		tile_meshes[pos].position = world_pos
		tile_meshes[pos].rotation_degrees.y = node_rotation
		# Apply center offset when rotating
		if node_rotation != 0.0:
			_apply_rotation_center_offset(tile_meshes[pos])
		else:
			# Reset to corner if no rotation
			tile_meshes[pos].position = world_pos
	else:
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.position = world_pos
		mesh_instance.rotation_degrees.y = node_rotation
		mesh_instance.process_priority = 1
		
		# Apply center offset when rotating
		if node_rotation != 0.0:
			_apply_rotation_center_offset(mesh_instance)
		
		var static_body = StaticBody3D.new()
		var collision_shape = CollisionShape3D.new()
		var box_shape = BoxShape3D.new()
		box_shape.size = Vector3(grid_size, grid_size, grid_size)
		collision_shape.shape = box_shape
		collision_shape.position = Vector3(grid_size/2, grid_size/2, grid_size/2)
		static_body.add_child(collision_shape)
		mesh_instance.add_child(static_body)
		
		parent_node.add_child(mesh_instance)
		tile_meshes[pos] = mesh_instance


func _apply_rotation_center_offset(mesh_instance: MeshInstance3D):
	"""Offset the position so rotation happens around tile center.
	
	Always call this AFTER setting both position (reset to world_pos) and
	rotation_degrees on the instance. Uses the node's basis so the result
	is stable at any angle, not just multiples of 90 degrees.
	"""
	var center_offset = Vector3(grid_size * 0.5, 0, grid_size * 0.5)
	# Shift node origin to tile center in world space
	mesh_instance.position += center_offset
	# Undo that shift in local (rotated) space via the node's basis,
	# keeping the mesh vertices at the same world position.
	mesh_instance.position -= mesh_instance.basis * center_offset

func _flush_without_threading():
	"""Fast path for small updates (edit mode)"""
	# Expand dirty set to include neighbors, matching the threaded flush path.
	# This ensures adjacent tiles re-cull their faces correctly (e.g. after rotation).
	var to_update: Dictionary = {}
	for pos in dirty_tiles.keys():
		to_update[pos] = true
		for offset in [
			Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1),
			Vector3i(1, 0, 1), Vector3i(1, 0, -1),
			Vector3i(-1, 0, 1), Vector3i(-1, 0, -1)
		]:
			var neighbor_pos = pos + offset
			if neighbor_pos in tiles:
				to_update[neighbor_pos] = true

	for pos in to_update.keys():
		if pos in tiles:
			_immediate_update_tile_mesh(pos)

	dirty_tiles.clear()
	
	# Print corner summary for debugging
	#if mesh_generator and mesh_generator.culling_manager:
	#	mesh_generator.culling_manager.print_corner_summary()

# ============================================================================
# NEIGHBOR QUERIES
# ============================================================================

func get_neighbors(pos: Vector3i) -> Dictionary:
	var neighbors : Dictionary = {}
	# Cardinal neighbors
	neighbors[MeshGenerator.NeighborDir.NORTH] = tiles.get(pos + Vector3i(0, 0, -1), -1)
	neighbors[MeshGenerator.NeighborDir.SOUTH] = tiles.get(pos + Vector3i(0, 0, 1), -1)
	neighbors[MeshGenerator.NeighborDir.EAST] = tiles.get(pos + Vector3i(1, 0, 0), -1)
	neighbors[MeshGenerator.NeighborDir.WEST] = tiles.get(pos + Vector3i(-1, 0, 0), -1)
	neighbors[MeshGenerator.NeighborDir.UP] = tiles.get(pos + Vector3i(0, 1, 0), -1)
	neighbors[MeshGenerator.NeighborDir.DOWN] = tiles.get(pos + Vector3i(0, -1, 0), -1)
	# Diagonal neighbors
	neighbors[MeshGenerator.NeighborDir.DIAGONAL_NW] = tiles.get(pos + Vector3i(-1, 0, -1), -1)
	neighbors[MeshGenerator.NeighborDir.DIAGONAL_NE] = tiles.get(pos + Vector3i(1, 0, -1), -1)
	neighbors[MeshGenerator.NeighborDir.DIAGONAL_SW] = tiles.get(pos + Vector3i(-1, 0, 1), -1)
	neighbors[MeshGenerator.NeighborDir.DIAGONAL_SE] = tiles.get(pos + Vector3i(1, 0, 1), -1)
	return neighbors

# ============================================================================
# DEBUG HELPERS
# ============================================================================

func print_corner_debug():
	"""Manually print the corner summary - call this after placing tiles"""
	if mesh_generator and mesh_generator.culling_manager:
		mesh_generator.culling_manager.print_corner_summary()
	else:
		print("Corner debug not available - culling_manager not initialized")

# ============================================================================
# CLEANUP
# ============================================================================

func cleanup() -> void:
	# Signal stop immediately — tick() checks this flag and calls _finalise_flush()
	# which stops the worker thread without blocking the main thread on await.
	should_stop_thread = true

	# Drain the queue under the mutex to avoid a race with the worker thread.
	if generation_mutex == null:
		generation_mutex = Mutex.new()
	generation_mutex.lock()
	mesh_generation_queue.clear()
	generation_mutex.unlock()

	# Wait for worker thread — queue is empty so it exits almost immediately.
	if worker_thread and worker_thread.is_started():
		worker_thread.wait_to_finish()
	worker_thread = null

	# Force-finalise the flush if one was in progress. No await, no blocking.
	if is_flushing:
		_finalise_flush(false)
