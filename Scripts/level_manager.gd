class_name LevelSaveLoad extends RefCounted

# Save format version for future compatibility
const SAVE_VERSION = 1

# ============================================================================
# SAVE LEVEL DATA
# ============================================================================

static func save_level(tilemap: TileMap3D, y_level_manager: YLevelManager, filepath: String, material_palette = null) -> bool:
	var save_data: Dictionary = {
		"version": SAVE_VERSION,
		"grid_size": tilemap.grid_size,
		"tiles": _serialize_tiles(tilemap.tiles),
		"tile_materials": _serialize_tile_materials(tilemap.tile_materials),
		"tile_step_counts": _serialize_step_counts(tilemap.tile_step_counts),
		"tile_rotations": _serialize_rotations(tilemap.tile_rotations),
		"y_level_offsets": _serialize_offsets(y_level_manager.y_level_offsets),
		"metadata": {
			"saved_at": Time.get_datetime_string_from_system(),
			"tile_count": tilemap.tiles.size()
		}
	}
	
	# Add materials palette if provided
	if material_palette and material_palette.has_method("get_material_data_at_index"):
		save_data["materials_palette"] = _serialize_materials_palette(material_palette)
	
	var json_string: String = JSON.stringify(save_data, "\t")

	# Write to a temp file first, then rename over the target atomically.
	# This ensures a force-kill mid-save never leaves a corrupt/truncated file —
	# the old file survives intact until the new one is fully written.
	var tmp_path: String = filepath + ".tmp"
	var file: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)

	if file == null:
		push_error("Failed to open temp file for writing: " + tmp_path)
		return false

	file.store_string(json_string)
	file.close()

	# Atomic rename: old file replaced only after new data is fully on disk.
	var dir: DirAccess = DirAccess.open(tmp_path.get_base_dir())
	if dir == null or dir.rename(tmp_path, filepath) != OK:
		push_error("Failed to rename temp save file to: " + filepath)
		return false
	
	print("Level saved successfully to: ", filepath)
	print("  - Tiles saved: ", tilemap.tiles.size())
	print("  - Tile materials saved: ", tilemap.tile_materials.size())
	print("  - Stair step counts saved: ", tilemap.tile_step_counts.size())
	print("  - Tile rotations saved: ", tilemap.tile_rotations.size())
	print("  - Y-levels with offsets: ", y_level_manager.y_level_offsets.size())
	
	return true


# ============================================================================
# LOAD LEVEL DATA
# ============================================================================

static func load_level_from_data(tilemap: TileMap3D, y_level_manager: YLevelManager, filepath: String, save_data: Dictionary, material_palette = null, progress_callback: Callable = Callable()) -> bool:
	"""Load a level from pre-parsed save data. Called by level_editor after
	JSON parsing has already been done on a deferred frame."""
	if not _validate_save_data(save_data):
		push_error("Invalid save data format")
		return false
	return _load_level_from_save_data(tilemap, y_level_manager, filepath, save_data, material_palette, progress_callback)


static func load_level(tilemap: TileMap3D, y_level_manager: YLevelManager, filepath: String, material_palette = null, progress_callback: Callable = Callable()) -> bool:
	"""Load a level from a filepath. Reads and parses JSON then delegates."""
	var file: FileAccess = FileAccess.open(filepath, FileAccess.READ)
	if file == null:
		push_error("Failed to open file for reading: " + filepath)
		return false
	var json_string: String = file.get_as_text()
	file.close()
	var json: JSON = JSON.new()
	if json.parse(json_string) != OK:
		push_error("Failed to parse JSON: " + json.get_error_message())
		return false
	if not _validate_save_data(json.data):
		push_error("Invalid save data format")
		return false
	return _load_level_from_save_data(tilemap, y_level_manager, filepath, json.data, material_palette, progress_callback)


static func _load_level_from_save_data(tilemap: TileMap3D, y_level_manager: YLevelManager, filepath: String, save_data: Dictionary, material_palette = null, progress_callback: Callable = Callable()) -> bool:
	tilemap.tile_manager.cleanup()
	_clear_level(tilemap, y_level_manager)
	
	# Load grid size (optional - warn if different)
	if save_data.has("grid_size") and save_data["grid_size"] != tilemap.grid_size:
		push_warning("Saved grid_size (" + str(save_data["grid_size"]) + 
					 ") differs from current (" + str(tilemap.grid_size) + ")")
	
	# Load Y-level offsets first
	_deserialize_offsets(save_data["y_level_offsets"], y_level_manager)
	
	# Load materials palette if present
	if save_data.has("materials_palette") and material_palette:
		_deserialize_materials_palette(save_data["materials_palette"], material_palette)
	
	# Load tiles with batch mode for performance
	tilemap.set_batch_mode(true)
	var tiles_loaded: int = _deserialize_tiles(save_data["tiles"], tilemap)
	
	# Load tile materials if present
	if save_data.has("tile_materials"):
		_deserialize_tile_materials(save_data["tile_materials"], tilemap)
	
	# Load tile step counts if present
	if save_data.has("tile_step_counts"):
		_deserialize_step_counts(save_data["tile_step_counts"], tilemap)

	# Load tile rotations if present
	if save_data.has("tile_rotations"):
		_deserialize_rotations(save_data["tile_rotations"], tilemap)

	# Re-evaluate corner tiles after all tiles are loaded
	var corners_fixed: int = _reevaluate_corner_tiles(tilemap)

	# Register a one-shot callback that fires after the async flush fully
	# completes. It handles three things:
	#
	# 1. Rotations — mesh_generator uses tile_rotations at generation time, so
	#    rotated tiles must be regenerated after the flush (not during it).
	#
	# 2. Palette materials — _apply_mesh_to_scene applies materials during the
	#    flush, but the rotation regeneration above creates fresh meshes without
	#    re-applying palette overrides. A final pass guarantees every painted
	#    tile shows the correct material on all surfaces.
	#
	# 3. Top plane — rebuilt last, after meshes and materials are both final.
	# Flush 1 reports 0->50%, flush 2 reports 50->100%.
	var first_flush_callback: Callable = Callable()
	if progress_callback.is_valid():
		first_flush_callback = func(done: int, total: int) -> void:
			progress_callback.call(done, total * 2)
	tilemap.tile_manager.flush_progress_callback = first_flush_callback
	tilemap.tile_manager.flush_completed_callback = func():
		# Step 1: re-apply palette materials to ALL surfaces (TOP, SIDES, BOTTOM) of
		# every painted tile. Name-based lookup is safe regardless of surface index.
		if not tilemap.tile_materials.is_empty() and tilemap.material_palette_ref:
			print("  Re-applying materials to ", tilemap.tile_materials.size(), " tiles...")
			for pos in tilemap.tile_materials:
				var material_index: int = tilemap.tile_materials[pos]
				if pos in tilemap.tile_meshes:
					var top_mat   = tilemap.material_palette_ref.get_material_for_surface(material_index, 0)
					var sides_mat: Material = tilemap.material_palette_ref.get_material_for_surface(material_index, 1)
					var bot_mat   = tilemap.material_palette_ref.get_material_for_surface(material_index, 2)
					TileMap3D.apply_palette_materials_to_mesh(tilemap.tile_meshes[pos], [top_mat, sides_mat, bot_mat])
			print("  ✓ Materials re-applied")

		# Step 2: rebuild top plane with initial meshes
		tilemap.rebuild_top_plane_mesh()

		tilemap.tile_manager.disable_caching_this_flush = false

		# Step 3: targeted second pass — only regenerate tiles whose culling
		# depends on the full tile set being known:
		#   - Tiles with a tile above (simple/flat-box) — their top and side
		#     visibility depends on whether cardinal neighbors are bulge tiles
		#   - Their cardinal neighbors — bulge tiles whose side faces toward a
		#     simple tile need correct _should_render_side_face evaluation
		#   - Rotated tiles — need tile_rotations which is fully loaded now
		var second_pass: Dictionary[Vector3i, bool] = {}
		for pos in tilemap.tiles:
			var needs_second_pass: bool = false
			if (pos + Vector3i(0, 1, 0)) in tilemap.tiles:
				needs_second_pass = true  # Simple/flat-box tile
			if pos in tilemap.tile_rotations:
				needs_second_pass = true  # Rotated tile
			if needs_second_pass:
				second_pass[pos] = true
				for offset in [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]:
					var n: Vector3i = pos + offset
					if n in tilemap.tiles:
						second_pass[n] = true

		if not second_pass.is_empty():
			print("  Queuing targeted re-cull pass (", second_pass.size(), " tiles, async)...")
			var second_flush_callback: Callable = Callable()
			if progress_callback.is_valid():
				second_flush_callback = func(done: int, total: int) -> void:
					progress_callback.call(total + done, total * 2)
			tilemap.tile_manager.flush_progress_callback = second_flush_callback
			tilemap.tile_manager.flush_completed_callback = func():
				print("  ✓ Targeted re-cull pass done")
				# Re-apply materials to ALL painted tiles — the flush expanded
				# to include neighbors beyond second_pass, so we must cover all.
				if not tilemap.tile_materials.is_empty() and tilemap.material_palette_ref:
					for pos in tilemap.tile_materials:
						if pos in tilemap.tile_meshes:
							var material_index: int = tilemap.tile_materials[pos]
							var top_mat   = tilemap.material_palette_ref.get_material_for_surface(material_index, 0)
							var sides_mat: Material = tilemap.material_palette_ref.get_material_for_surface(material_index, 1)
							var bot_mat   = tilemap.material_palette_ref.get_material_for_surface(material_index, 2)
							TileMap3D.apply_palette_materials_to_mesh(tilemap.tile_meshes[pos], [top_mat, sides_mat, bot_mat])
				tilemap.rebuild_top_plane_mesh()
			tilemap.tile_manager.clear_mesh_cache()
			tilemap.set_batch_mode(true)
			for pos in second_pass:
				tilemap.tile_manager.mark_dirty(pos)
			tilemap.set_batch_mode(false)

	# CRITICAL: Ensure culling is ENABLED for the flush
	# Disable caching for this flush to ensure accurate corner evaluation.
	# NOTE: The flag is reset to false inside flush_completed_callback above,
	# so it stays true for the entire async flush instead of being reset
	# immediately here before the worker thread has read it.
	tilemap.tile_manager.disable_caching_this_flush = true
	tilemap.tile_manager.clear_mesh_cache()
	print("  Caching disabled for this flush to ensure correct corner detection")
	
	# Now end batch mode, which will trigger flush with correct neighbor data
	tilemap.set_batch_mode(false)
	
	print("Level loaded successfully from: ", filepath)
	print("  - Tiles loaded: ", tiles_loaded)
	print("  - Corners corrected: ", corners_fixed)
	print("  - Tile materials loaded: ", tilemap.tile_materials.size())
	print("  - Stair step counts loaded: ", tilemap.tile_step_counts.size())
	print("  - Tile rotations loaded: ", tilemap.tile_rotations.size())
	print("  - Y-levels with offsets: ", y_level_manager.y_level_offsets.size())
	if save_data.has("metadata") and save_data["metadata"].has("saved_at"):
		print("  - Originally saved: ", save_data["metadata"]["saved_at"])
	
	return true

# ============================================================================
# SERIALIZATION HELPERS
# ============================================================================

static func _serialize_vec3i_dict(dict: Dictionary, value_key: String) -> Array:
	# Serialize any Vector3i-keyed dictionary to [{x,y,z,value_key: value}, ...].
	var arr: Array = []
	for pos in dict.keys():
		var entry: Dictionary = {"x": pos.x, "y": pos.y, "z": pos.z}
		entry[value_key] = dict[pos]
		arr.append(entry)
	return arr


static func _serialize_tiles(tiles: Dictionary) -> Array:
	return _serialize_vec3i_dict(tiles, "type")


static func _serialize_tile_materials(tile_materials: Dictionary) -> Array:
	return _serialize_vec3i_dict(tile_materials, "material_index")


static func _serialize_step_counts(tile_step_counts: Dictionary) -> Array:
	return _serialize_vec3i_dict(tile_step_counts, "steps")


static func _serialize_rotations(tile_rotations: Dictionary) -> Array:
	return _serialize_vec3i_dict(tile_rotations, "rotation")


static func _serialize_offsets(offsets: Dictionary) -> Dictionary:
	var offset_data: Dictionary = {}
	
	for y_level in offsets.keys():
		var offset: Vector2 = offsets[y_level]
		offset_data[str(y_level)] = {
			"x": offset.x,
			"z": offset.y
		}
	
	return offset_data


static func _serialize_materials_palette(palette) -> Array:
	"""Serialize materials palette"""
	var materials_array: Array = []
	
	# Get count by checking materials array
	if palette.has_method("get_material_data_at_index"):
		var idx: int = 0
		while true:
			var material_data: Dictionary = palette.get_material_data_at_index(idx)
			if material_data.is_empty():
				break
			materials_array.append(material_data)
			idx += 1
	
	return materials_array


# ============================================================================
# DESERIALIZATION HELPERS
# ============================================================================

static func _deserialize_vec3i_dict(arr: Array, value_key: String) -> Dictionary:
	# Deserialize [{x,y,z,value_key: value}, ...] back to a Vector3i-keyed dictionary.
	var result: Dictionary = {}
	for entry in arr:
		if not entry is Dictionary:
			continue
		if not (entry.has("x") and entry.has("y") and entry.has("z") and entry.has(value_key)):
			continue
		result[Vector3i(entry["x"], entry["y"], entry["z"])] = entry[value_key]
	return result


static func _deserialize_tiles(tile_array: Array, tilemap: TileMap3D) -> int:
	var tile_dict: Dictionary = _deserialize_vec3i_dict(tile_array, "type")
	for pos in tile_dict:
		tilemap.place_tile(pos, tile_dict[pos])
	return tile_dict.size()


static func _deserialize_offsets(offset_data: Dictionary, y_level_manager: YLevelManager):
	for y_level_str in offset_data.keys():
		var y_level: int = int(y_level_str)
		var offset: Dictionary = offset_data[y_level_str]
		
		if offset.has("x") and offset.has("z"):
			y_level_manager.set_offset(y_level, offset["x"], offset["z"])


static func _deserialize_tile_materials(material_array: Array, tilemap: TileMap3D):
	var d: Dictionary = _deserialize_vec3i_dict(material_array, "material_index")
	for pos in d:
		tilemap.tile_materials[pos] = d[pos]


static func _deserialize_step_counts(step_counts_array: Array, tilemap: TileMap3D):
	var d: Dictionary = _deserialize_vec3i_dict(step_counts_array, "steps")
	for pos in d:
		tilemap.tile_step_counts[pos] = d[pos]


static func _deserialize_rotations(rotations_array: Array, tilemap: TileMap3D):
	var d: Dictionary = _deserialize_vec3i_dict(rotations_array, "rotation")
	for pos in d:
		tilemap.tile_rotations[pos] = float(d[pos])


static func _deserialize_materials_palette(materials_array: Array, palette):
	"""Deserialize materials palette"""
	# FIXED: Clear all materials first (including defaults) to maintain correct indices
	if palette.has_method("_clear_all_materials"):
		palette._clear_all_materials()
		print("  Cleared existing materials from palette")
	
	# Load materials from save file
	var loaded_count: int = 0
	for material_data in materials_array:
		if material_data is Dictionary and material_data.has("name"):
			# Call the material creation method
			if palette.has_method("_on_material_created"):
				palette._on_material_created(material_data)
				loaded_count += 1
	
	print("  Loaded ", loaded_count, " materials into palette")


static func _reevaluate_corner_tiles(tilemap: TileMap3D) -> int:
	"""
	Re-evaluate tile types for corners after loading.
	This ensures proper corner detection even when auto-detection is disabled.
	Returns the number of tiles that were corrected.
	"""
	var diagonal_selector: DiagonalTileSelector = DiagonalTileSelector.new()
	var corrections: int = 0
	var affected_tiles: Dictionary = {}  # Track all tiles that need mesh updates
	
	# First pass: identify which tiles should be corners
	var tiles_to_correct: Array = []
	
	for pos in tilemap.tiles.keys():
		var current_tile_type: int = tilemap.tiles[pos]
		var config = diagonal_selector.get_tile_configuration(pos, tilemap.tiles)
		
		# If this should be an inner corner but isn't
		if config.corner_type == DiagonalTileSelector.CornerType.INNER_CORNER:
			if current_tile_type != DiagonalTileSelector.TILE_INNER_CORNER:
				tiles_to_correct.append({
					"pos": pos,
					"old_type": current_tile_type,
					"new_type": DiagonalTileSelector.TILE_INNER_CORNER,
					"rotation": config.rotation
				})
		# If this is marked as corner but shouldn't be
		elif current_tile_type == DiagonalTileSelector.TILE_INNER_CORNER:
			if config.corner_type != DiagonalTileSelector.CornerType.INNER_CORNER:
				tiles_to_correct.append({
					"pos": pos,
					"old_type": current_tile_type,
					"new_type": DiagonalTileSelector.TILE_FULL_BLOCK,
					"rotation": 0.0
				})
	
	# Second pass: apply corrections
	for correction in tiles_to_correct:
		var pos: Vector3i = correction["pos"]
		tilemap.tiles[pos] = correction["new_type"]
		
		# Store rotation if it's a corner
		if correction["new_type"] == DiagonalTileSelector.TILE_INNER_CORNER:
			tilemap.tile_rotations[pos] = correction["rotation"]
		elif pos in tilemap.tile_rotations:
			# Clear rotation if it's not a corner anymore
			tilemap.tile_rotations.erase(pos)
		
		# Mark this tile and all neighbors
		affected_tiles[pos] = true
		
		# Mark all neighbors (they need to regenerate to show/hide faces correctly)
		for offset in [
			Vector3i(1,0,0), Vector3i(-1,0,0),
			Vector3i(0,1,0), Vector3i(0,-1,0),
			Vector3i(0,0,1), Vector3i(0,0,-1),
			Vector3i(1, 0, 1), Vector3i(1, 0, -1),
			Vector3i(-1, 0, 1), Vector3i(-1, 0, -1)
		]:
			var neighbor_pos: Vector3i = pos + offset
			if neighbor_pos in tilemap.tiles:
				affected_tiles[neighbor_pos] = true
		
		corrections += 1
	
	# Third pass: mark all affected tiles as dirty
	for pos in affected_tiles.keys():
		tilemap.tile_manager.mark_dirty(pos)
	
	if corrections > 0:
		print("  Re-evaluated ", tilemap.tiles.size(), " tiles, corrected ", corrections, " corner tiles")
		print("  Marked ", affected_tiles.size(), " tiles (including neighbors) for mesh regeneration")
	
	return corrections


# ============================================================================
# VALIDATION
# ============================================================================

static func _validate_save_data(data) -> bool:
	if not data is Dictionary:
		return false
	
	if not data.has("version"):
		return false
	
	if not data.has("tiles") or not data["tiles"] is Array:
		return false
	
	if not data.has("y_level_offsets") or not data["y_level_offsets"] is Dictionary:
		return false
	
	return true


# ============================================================================
# UTILITY
# ============================================================================

static func _clear_level(tilemap: TileMap3D, y_level_manager: YLevelManager):
	tilemap._bulk_clearing = true
	tilemap.tile_manager.batch_mode = true  # suppress immediate neighbor rebuilds
	var tiles_to_remove: Array = tilemap.tiles.keys()
	for pos in tiles_to_remove:
		tilemap.remove_tile(pos)
	tilemap.tile_manager.batch_mode = false
	tilemap.tile_manager.dirty_tiles.clear()  # discard, we're replacing everything
	tilemap._bulk_clearing = false
	tilemap.tile_materials.clear()
	tilemap.rebuild_top_plane_mesh()
	var levels_to_clear: Array = y_level_manager.y_level_offsets.keys()
	for level in levels_to_clear:
		y_level_manager.clear_offset(level)


# ============================================================================
# FILE UTILITIES
# ============================================================================

static func get_save_filepath(base_name: String = "level") -> String:
	var timestamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	return AppConfig.saves_dir + base_name + "_" + timestamp + ".level"


static func ensure_save_directory() -> void:
	# Directory creation is now handled by AppConfig._ensure_directories().
	# This function is kept for call-site compatibility.
	pass


static func list_saved_levels() -> Array:
	var levels: Array = []
	var dir: DirAccess = DirAccess.open(AppConfig.saves_dir)
	if dir:
		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".level"):
				levels.append(file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	return levels
