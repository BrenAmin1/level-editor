class_name YLevelManager extends RefCounted

# Manages Y-level offsets and switching
var tilemap: TileMap3D
var grid_visualizer: GridVisualizer

# Y-level offsets: Dictionary[int, Vector2] - maps y_level to (x_offset, z_offset)
var y_level_offsets: Dictionary = {}

# ============================================================================
# SETUP
# ============================================================================

func setup(tm: TileMap3D, grid_vis: GridVisualizer):
	tilemap = tm
	grid_visualizer = grid_vis

# ============================================================================
# OFFSET MANAGEMENT
# ============================================================================

func get_offset(y_level: int) -> Vector2:
	return y_level_offsets.get(y_level, Vector2.ZERO)


func set_offset(y_level: int, x_offset: float, z_offset: float):
	y_level_offsets[y_level] = Vector2(x_offset, z_offset)
	tilemap.refresh_y_level(y_level)
	if grid_visualizer:
		grid_visualizer.set_y_level_offset(y_level, Vector2(x_offset, z_offset))


func clear_offset(y_level: int):
	y_level_offsets.erase(y_level)
	tilemap.refresh_y_level(y_level)
	if grid_visualizer:
		grid_visualizer.set_y_level_offset(y_level, Vector2.ZERO)


func change_y_level(new_level: int):
	print("Y-Level: ", new_level)
	var offset = get_offset(new_level)
	if grid_visualizer:
		grid_visualizer.set_y_level_offset(new_level, offset)
