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
		# MUST set to null after wait_to_finish() before creating new thread
		worker_thread = null
	
	print("\n=== BATCH FLUSH START ===")
	print("Dirty tiles: ", dirty_tiles.size())
	
	# TECHNIQUE 3: Collect all tiles that need updates (dirty + their neighbors)
	var tiles_to_update = {}
	
	for pos in dirty_tiles.keys():
		tiles_to_update[pos] = true
		
		# Add all neighbors (cardinal + diagonal)
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
	
	var positions = tiles_to_update.keys()
	print("Total tiles to update (including neighbors): ", positions.size())
	
	# TECHNIQUE 5: Dynamic batch sizing based on operation size
	var batch_size = 50
	if positions.size() > 5000:
		batch_size = 20
		print("Large operation detected - using smaller batches (20)")
	elif positions.size() > 1000:
		batch_size = 30
		print("Medium operation detected - using medium batches (30)")
	
	# Reset cache statistics
	cache_hits = 0
	cache_misses = 0
	
	# TECHNIQUE 9: Start worker thread for mesh generation
	should_stop_thread = false
	if generation_mutex == null:
		generation_mutex = Mutex.new()
	mesh_generation_queue = positions.duplicate()
	generated_meshes.clear()
	
	# Create fresh thread object (required in Godot 4 - can't reuse after wait_to_finish)
	worker_thread = Thread.new()
	var thread_error = worker_thread.start(_generate_meshes_threaded)
	if thread_error != OK:
		push_error("Failed to start worker thread: ", thread_error)
		worker_thread = null
		is_flushing = false
		return
	
	print("Worker thread started")
	
	# TECHNIQUE 6: Process generated meshes as they complete
	var start_time = Time.get_ticks_msec()
	var applied_count = 0
	var last_progress_print = 0
	
	# Use a try-finally pattern to ensure cleanup
	var completed_successfully = false
	
	while applied_count < positions.size():
		# Check for completed meshes from worker thread
		generation_mutex.lock()
		var available_meshes = generated_meshes.keys()
		var thread_alive = worker_thread != null and worker_thread.is_alive()
		generation_mutex.unlock()
		
		# If thread just finished, call wait_to_finish immediately to acknowledge completion
		if worker_thread != null and not thread_alive and not worker_thread.is_started():
			# Thread finished but we haven't called wait_to_finish yet
			pass  # We'll handle this in cleanup
		elif worker_thread != null and not thread_alive:
			# Thread is done, acknowledge it now to prevent warning
			worker_thread.wait_to_finish()
		
		# If thread is done AND no meshes available AND we haven't applied everything, something went wrong
		if not thread_alive and available_meshes.is_empty() and applied_count < positions.size():
			break
		
		# Apply a batch of completed meshes
		var processed_this_frame = 0
		for pos in available_meshes:
			if processed_this_frame >= batch_size:
				break
			
			generation_mutex.lock()
			var mesh = generated_meshes.get(pos)
			if mesh:
				generated_meshes.erase(pos)
			generation_mutex.unlock()
			
			if mesh:
				_apply_mesh_to_scene(pos, mesh)
				applied_count += 1
				processed_this_frame += 1
		
		# Yield to keep framerate smooth
		await tile_map.parent_node.get_tree().process_frame
		
		# Progress feedback every 500 tiles or at completion
		if positions.size() > 100 and (applied_count - last_progress_print >= 500 or applied_count == positions.size()):
			var progress_elapsed = Time.get_ticks_msec() - start_time
			var rate = float(applied_count) / (progress_elapsed / 1000.0) if progress_elapsed > 0 else 0.0
			print("  Progress: ", applied_count, "/", positions.size(), " (", int(rate), " tiles/sec)")
			last_progress_print = applied_count
	
	completed_successfully = (applied_count >= positions.size())
	
	# ALWAYS cleanup thread, even if interrupted
	_cleanup_worker_thread()
	_cleanup_worker_thread()
	
	# TECHNIQUE 8: Re-enable culling
	if mesh_generator.culling_manager:
		mesh_generator.culling_manager.batch_mode_skip_culling = false
	
	# Print cache statistics
	if completed_successfully:
		var total_requests = cache_hits + cache_misses
		var hit_rate = (float(cache_hits) / total_requests * 100.0) if total_requests > 0 else 0.0
		print("Cache: ", cache_hits, " hits / ", cache_misses, " misses (", "%.1f" % hit_rate, "% hit rate)")
		
		var elapsed = Time.get_ticks_msec() - start_time
		print("✓ Flush complete in ", elapsed / 1000.0, " seconds")
	else:
		print("⚠ Flush interrupted")
	
	dirty_tiles.clear()
	print("=== BATCH FLUSH END ===\n")
	
	is_flushing = false


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


# TECHNIQUE 9: Worker thread function for mesh generation
func _generate_meshes_threaded():
	while not mesh_generation_queue.is_empty() and not should_stop_thread:
		var pos = mesh_generation_queue.pop_front()
		
		if pos not in tiles:
			continue
		
		var tile_type = tiles[pos]
		var rotation = tile_map.tile_rotations.get(pos, 0.0)
		var neighbors = get_neighbors(pos)
		
		# MESH CACHING: Create cache key
		var cache_key = _create_cache_key(tile_type, neighbors, rotation)
		
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
				mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation)
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
func _create_cache_key(tile_type: int, neighbors: Dictionary, rotation: float) -> String:
	# Hash: tile_type + 6 neighbors + rotation (rounded to nearest 15°)
	var rounded_rotation = round(rotation / 15.0) * 15.0
	var n = neighbors
	return "%d_%d%d%d%d%d%d_%.0f" % [
		tile_type,
		n[MeshGenerator.NeighborDir.NORTH],
		n[MeshGenerator.NeighborDir.SOUTH],
		n[MeshGenerator.NeighborDir.EAST],
		n[MeshGenerator.NeighborDir.WEST],
		n[MeshGenerator.NeighborDir.UP],
		n[MeshGenerator.NeighborDir.DOWN],
		rounded_rotation
	]


# TECHNIQUE 6: Apply pre-generated mesh to scene (main thread only)
func _apply_mesh_to_scene(pos: Vector3i, mesh: ArrayMesh):
	if not parent_node:
		return
	
	if pos not in tiles:
		return
	
	var rotation = tile_map.tile_rotations.get(pos, 0.0)
	var world_pos = grid_to_world(pos)
	
	if pos in tile_meshes:
		# Update existing mesh instance
		tile_meshes[pos].mesh = mesh
		tile_meshes[pos].position = world_pos
		tile_meshes[pos].rotation_degrees.y = rotation
		if rotation != 0.0:
			_apply_rotation_center_offset(tile_meshes[pos])
	else:
		# Create new mesh instance
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.position = world_pos
		mesh_instance.rotation_degrees.y = rotation
		mesh_instance.process_priority = 1
		
		if rotation != 0.0:
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
	# Preserve existing rotation if tile already exists
	var existing_rotation = 0.0
	if pos in tiles and pos in tile_map.tile_rotations:
		existing_rotation = tile_map.tile_rotations[pos]
	
	# Manual placement mode - use the exact tile type the user selected
	var actual_tile_type = tile_type
	
	# Only use auto-detection if explicitly enabled
	if auto_tile_selection_enabled:
		var config = diagonal_selector.get_tile_configuration(pos, tiles)
		if config.corner_type == DiagonalTileSelector.CornerType.INNER_CORNER:
			actual_tile_type = config.tile_type
	
	# Store the tile
	tiles[pos] = actual_tile_type
	
	# Preserve rotation
	if existing_rotation != 0.0:
		tile_map.tile_rotations[pos] = existing_rotation
	
	if batch_mode:
		# TECHNIQUE 3: In batch mode, ONLY mark this tile as dirty
		# DON'T mark neighbors yet - we'll handle them all at once in flush_batch_updates()
		mark_dirty(pos)
	else:
		# Normal mode: immediate update with neighbors
		update_tile_mesh(pos)
		
		# Update all neighbors (including diagonals)
		for offset in [
			Vector3i(1,0,0), Vector3i(-1,0,0),
			Vector3i(0,1,0), Vector3i(0,-1,0),
			Vector3i(0,0,1), Vector3i(0,0,-1),
			Vector3i(1, 0, 1), Vector3i(1, 0, -1),
			Vector3i(-1, 0, 1), Vector3i(-1, 0, -1)
		]:
			var neighbor_pos = pos + offset
			if neighbor_pos in tiles:
				# Only recalculate neighbor's tile type if auto-detection is enabled
				if auto_tile_selection_enabled:
					var neighbor_config = diagonal_selector.get_tile_configuration(neighbor_pos, tiles)
					if neighbor_config.corner_type == DiagonalTileSelector.CornerType.INNER_CORNER:
						tiles[neighbor_pos] = DiagonalTileSelector.TILE_INNER_CORNER
				update_tile_mesh(neighbor_pos)


func remove_tile(pos: Vector3i):
	if pos not in tiles:
		return
	
	tiles.erase(pos)
	
	# Clean up rotation data
	if pos in tile_map.tile_rotations:
		tile_map.tile_rotations.erase(pos)
	
	if pos in tile_meshes:
		tile_meshes[pos].queue_free()
		tile_meshes.erase(pos)
	
	if batch_mode:
		# TECHNIQUE 3: In batch mode, neighbors will be updated in flush_batch_updates()
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
	
	# Use custom mesh if available, otherwise generate default
	var mesh: ArrayMesh
	if tile_type in custom_meshes:
		var neighbors = get_neighbors(pos)
		# PASS ROTATION to mesh generator
		mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation)
	else:
		var neighbors = get_neighbors(pos)
		mesh = mesh_generator.generate_tile_mesh(tile_type, neighbors)
	
	# Position at corner of grid cell
	var world_pos = grid_to_world(pos)
	
	if pos in tile_meshes:
		tile_meshes[pos].mesh = mesh
		tile_meshes[pos].position = world_pos
		tile_meshes[pos].rotation_degrees.y = rotation
		# Apply center offset when rotating
		if rotation != 0.0:
			_apply_rotation_center_offset(tile_meshes[pos])
	else:
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.position = world_pos
		mesh_instance.rotation_degrees.y = rotation
		mesh_instance.process_priority = 1
		
		# Apply center offset when rotating
		if rotation != 0.0:
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
	
	var mesh: ArrayMesh
	if tile_type in custom_meshes:
		# PASS ROTATION to mesh generator
		mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation_degrees)
	else:
		mesh = mesh_generator.generate_tile_mesh(tile_type, neighbors)
	
	# Position at corner of grid cell
	var world_pos = grid_to_world(pos)
	
	# Update existing mesh instance or create new one
	if pos in tile_meshes:
		tile_meshes[pos].mesh = mesh
		tile_meshes[pos].position = world_pos
		tile_meshes[pos].rotation_degrees.y = rotation_degrees
		# Apply center offset when rotating
		if rotation_degrees != 0.0:
			_apply_rotation_center_offset(tile_meshes[pos])
		else:
			# Reset to corner if no rotation
			tile_meshes[pos].position = world_pos
	else:
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.position = world_pos
		mesh_instance.rotation_degrees.y = rotation_degrees
		mesh_instance.process_priority = 1
		
		# Apply center offset when rotating
		if rotation_degrees != 0.0:
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
	"""Offset the position so rotation happens around tile center"""
	var center_offset = Vector3(grid_size * 0.5, 0, grid_size * 0.5)
	
	# Move position to center
	mesh_instance.position += center_offset
	
	# Translate mesh vertices back so they stay in place
	mesh_instance.translate_object_local(-center_offset)


# ============================================================================
# NEIGHBOR QUERIES
# ============================================================================

func get_neighbors(pos: Vector3i) -> Dictionary:
	var neighbors : Dictionary = {}
	neighbors[MeshGenerator.NeighborDir.NORTH] = tiles.get(pos + Vector3i(0, 0, -1), -1)
	neighbors[MeshGenerator.NeighborDir.SOUTH] = tiles.get(pos + Vector3i(0, 0, 1), -1)
	neighbors[MeshGenerator.NeighborDir.EAST] = tiles.get(pos + Vector3i(1, 0, 0), -1)
	neighbors[MeshGenerator.NeighborDir.WEST] = tiles.get(pos + Vector3i(-1, 0, 0), -1)
	neighbors[MeshGenerator.NeighborDir.UP] = tiles.get(pos + Vector3i(0, 1, 0), -1)
	neighbors[MeshGenerator.NeighborDir.DOWN] = tiles.get(pos + Vector3i(0, -1, 0), -1)
	return neighbors
