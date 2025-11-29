class_name LevelSaveLoad extends RefCounted

# Save format version for future compatibility
const SAVE_VERSION = 1

# ============================================================================
# SAVE LEVEL DATA
# ============================================================================

static func save_level(tilemap: TileMap3D, y_level_manager: YLevelManager, filepath: String) -> bool:
	var save_data = {
		"version": SAVE_VERSION,
		"grid_size": tilemap.grid_size,
		"tiles": _serialize_tiles(tilemap.tiles),
		"y_level_offsets": _serialize_offsets(y_level_manager.y_level_offsets),
		"metadata": {
			"saved_at": Time.get_datetime_string_from_system(),
			"tile_count": tilemap.tiles.size()
		}
	}
	
	var json_string = JSON.stringify(save_data, "\t")
	var file = FileAccess.open(filepath, FileAccess.WRITE)
	
	if file == null:
		push_error("Failed to open file for writing: " + filepath)
		return false
	
	file.store_string(json_string)
	file.close()
	
	print("Level saved successfully to: ", filepath)
	print("  - Tiles saved: ", tilemap.tiles.size())
	print("  - Y-levels with offsets: ", y_level_manager.y_level_offsets.size())
	
	return true


# ============================================================================
# LOAD LEVEL DATA
# ============================================================================

static func load_level(tilemap: TileMap3D, y_level_manager: YLevelManager, filepath: String) -> bool:
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
	
	# Load tiles with batch mode for performance
	tilemap.set_batch_mode(true)
	var tiles_loaded = _deserialize_tiles(save_data["tiles"], tilemap)
	tilemap.set_batch_mode(false)
	
	print("Level loaded successfully from: ", filepath)
	print("  - Tiles loaded: ", tiles_loaded)
	print("  - Y-levels with offsets: ", y_level_manager.y_level_offsets.size())
	if save_data.has("metadata") and save_data["metadata"].has("saved_at"):
		print("  - Originally saved: ", save_data["metadata"]["saved_at"])
	
	return true


# ============================================================================
# SERIALIZATION HELPERS
# ============================================================================

static func _serialize_tiles(tiles: Dictionary) -> Array:
	var tile_array = []
	
	for pos in tiles.keys():
		var tile_type = tiles[pos]
		tile_array.append({
			"x": pos.x,
			"y": pos.y,
			"z": pos.z,
			"type": tile_type
		})
	
	return tile_array


static func _serialize_offsets(offsets: Dictionary) -> Dictionary:
	var offset_data = {}
	
	for y_level in offsets.keys():
		var offset = offsets[y_level]
		offset_data[str(y_level)] = {
			"x": offset.x,
			"z": offset.y
		}
	
	return offset_data


# ============================================================================
# DESERIALIZATION HELPERS
# ============================================================================

static func _deserialize_tiles(tile_array: Array, tilemap: TileMap3D) -> int:
	var count = 0
	
	for tile_data in tile_array:
		if not tile_data is Dictionary:
			continue
		
		if not (tile_data.has("x") and tile_data.has("y") and 
				tile_data.has("z") and tile_data.has("type")):
			continue
		
		var pos = Vector3i(tile_data["x"], tile_data["y"], tile_data["z"])
		var tile_type = tile_data["type"]
		
		tilemap.place_tile(pos, tile_type)
		count += 1
	
	return count


static func _deserialize_offsets(offset_data: Dictionary, y_level_manager: YLevelManager):
	for y_level_str in offset_data.keys():
		var y_level = int(y_level_str)
		var offset = offset_data[y_level_str]
		
		if offset.has("x") and offset.has("z"):
			y_level_manager.set_offset(y_level, offset["x"], offset["z"])


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
