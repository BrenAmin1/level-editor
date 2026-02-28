class_name LevelSaveLoad extends RefCounted

# Save format version for future compatibility
const SAVE_VERSION = 1

# ============================================================================
# SAVE LEVEL DATA
# ============================================================================

static func save_level(tilemap: TileMap3D, y_level_manager: YLevelManager, filepath: String, material_palette = null) -> bool:
	var save_data = {
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
	
	var json_string = JSON.stringify(save_data, "\t")
	var file = FileAccess.open(filepath, FileAccess.WRITE)
	
	if file == null:
		push_error("Failed to open file for writing: " + filepath)
		return false
	
	file.store_string(json_string)
	file.close()
	
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

static func load_level(tilemap: TileMap3D, y_level_manager: YLevelManager, filepath: String, material_palette = null) -> bool:
	var file = FileAccess.open(filepath, FileAccess.READ)
	
	if file == null:
		push_error("Failed to open file for reading: " + filepath)
		return false
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	
	if parse_result != OK:
		push_error("Failed to parse JSON: " + json.get_error_message())
		return false
	
	var save_data = json.data
	
	# Validate save data
	if not _validate_save_data(save_data):
		push_error("Invalid save data format")
		return false
	
	# Clear existing level
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
	var tiles_loaded = _deserialize_tiles(save_data["tiles"], tilemap)
	
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
	var corners_fixed = _reevaluate_corner_tiles(tilemap)

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
	tilemap.tile_manager.flush_completed_callback = func():
		# Step 1: re-generate meshes for rotated tiles
		if not tilemap.tile_rotations.is_empty():
			print("  Applying rotations to ", tilemap.tile_rotations.size(), " tiles...")
			for pos in tilemap.tile_rotations:
				tilemap.tile_manager.update_tile_mesh(pos)
			print("  ✓ Rotations applied")

		# Step 2: re-apply palette materials to ALL surfaces (TOP, SIDES, BOTTOM) of
		# every painted tile. Name-based lookup is safe regardless of surface index.
		if not tilemap.tile_materials.is_empty() and tilemap.material_palette_ref:
			print("  Re-applying materials to ", tilemap.tile_materials.size(), " tiles...")
			for pos in tilemap.tile_materials:
				var material_index: int = tilemap.tile_materials[pos]
				if pos in tilemap.tile_meshes:
					var top_mat   = tilemap.material_palette_ref.get_material_for_surface(material_index, 0)
					var sides_mat = tilemap.material_palette_ref.get_material_for_surface(material_index, 1)
					var bot_mat   = tilemap.material_palette_ref.get_material_for_surface(material_index, 2)
					TileMap3D.apply_palette_materials_to_mesh(tilemap.tile_meshes[pos], [top_mat, sides_mat, bot_mat])
			print("  ✓ Materials re-applied")

		# Step 3: rebuild top plane now that all meshes and materials are final
		tilemap.rebuild_top_plane_mesh()

		# Re-enable caching now that the flush is fully done. Moving this into the
		# callback prevents a race where the flag was reset on the main thread
		# before the worker thread had a chance to read it.
		tilemap.tile_manager.disable_caching_this_flush = false

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
	var arr = []
	for pos in dict.keys():
		var entry = {"x": pos.x, "y": pos.y, "z": pos.z}
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
	var offset_data = {}
	
	for y_level in offsets.keys():
		var offset = offsets[y_level]
		offset_data[str(y_level)] = {
			"x": offset.x,
			"z": offset.y
		}
	
	return offset_data


static func _serialize_materials_palette(palette) -> Array:
	"""Serialize materials palette"""
	var materials_array = []
	
	# Get count by checking materials array
	if palette.has_method("get_material_data_at_index"):
		var idx = 0
		while true:
			var material_data = palette.get_material_data_at_index(idx)
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
	var tile_dict = _deserialize_vec3i_dict(tile_array, "type")
	for pos in tile_dict:
		tilemap.place_tile(pos, tile_dict[pos])
	return tile_dict.size()


static func _deserialize_offsets(offset_data: Dictionary, y_level_manager: YLevelManager):
	for y_level_str in offset_data.keys():
		var y_level = int(y_level_str)
		var offset = offset_data[y_level_str]
		
		if offset.has("x") and offset.has("z"):
			y_level_manager.set_offset(y_level, offset["x"], offset["z"])


static func _deserialize_tile_materials(material_array: Array, tilemap: TileMap3D):
	var d = _deserialize_vec3i_dict(material_array, "material_index")
	for pos in d:
		tilemap.tile_materials[pos] = d[pos]


static func _deserialize_step_counts(step_counts_array: Array, tilemap: TileMap3D):
	var d = _deserialize_vec3i_dict(step_counts_array, "steps")
	for pos in d:
		tilemap.tile_step_counts[pos] = d[pos]


static func _deserialize_rotations(rotations_array: Array, tilemap: TileMap3D):
	var d = _deserialize_vec3i_dict(rotations_array, "rotation")
	for pos in d:
		tilemap.tile_rotations[pos] = float(d[pos])


static func _deserialize_materials_palette(materials_array: Array, palette):
	"""Deserialize materials palette"""
	# FIXED: Clear all materials first (including defaults) to maintain correct indices
	if palette.has_method("_clear_all_materials"):
		palette._clear_all_materials()
		print("  Cleared existing materials from palette")
	
	# Load materials from save file
	var loaded_count = 0
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
	var diagonal_selector = DiagonalTileSelector.new()
	var corrections = 0
	var affected_tiles = {}  # Track all tiles that need mesh updates
	
	# First pass: identify which tiles should be corners
	var tiles_to_correct = []
	
	for pos in tilemap.tiles.keys():
		var current_tile_type = tilemap.tiles[pos]
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
		var pos = correction["pos"]
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
			var neighbor_pos = pos + offset
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
	# Clear all tiles
	var tiles_to_remove = tilemap.tiles.keys()
	for pos in tiles_to_remove:
		tilemap.remove_tile(pos)
	
	# Clear all Y-level offsets
	var levels_to_clear = y_level_manager.y_level_offsets.keys()
	for level in levels_to_clear:
		y_level_manager.clear_offset(level)


# ============================================================================
# FILE UTILITIES
# ============================================================================

static func get_save_filepath(base_name: String = "level") -> String:
	var timestamp = Time.get_datetime_string_from_system().replace(":", "-")
	return "user://saved_levels/" + base_name + "_" + timestamp + ".json"


static func ensure_save_directory():
	var dir = DirAccess.open("user://")
	if not dir.dir_exists("saved_levels"):
		dir.make_dir("saved_levels")


static func list_saved_levels() -> Array:
	ensure_save_directory()
	var levels = []
	var dir = DirAccess.open("user://saved_levels/")
	
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".json"):
				levels.append(file_name)
			file_name = dir.get_next()
		
		dir.list_dir_end()
	
	return levels
