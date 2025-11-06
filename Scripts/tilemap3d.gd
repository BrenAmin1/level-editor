class_name TileMap3D extends RefCounted

var tiles = {}  # Vector3i -> tile_type
var tile_meshes = {}  # Vector3i -> MeshInstance3D
var custom_meshes = {}  # tile_type -> ArrayMesh (custom loaded meshes)
var grid_size: float = 1.0
var parent_node: Node3D
var offset_provider: Callable

var custom_materials: Dictionary = {}  # tile_type -> Material
var mesh_loader: MeshLoader
var mesh_generator: MeshGenerator
var mesh_editor: MeshEditor
var material_manager: MaterialManager
var tile_manager: TileManager
var mesh_optimizer: MeshOptimizer

func _init(grid_sz: float = 1.0):
	grid_size = grid_sz


func set_parent(node: Node3D):
	parent_node = node


func set_offset_provider(provider: Callable):
	offset_provider = provider


func get_offset_for_y(y_level: int) -> Vector2:
	if offset_provider.is_valid():
		return offset_provider.call(y_level)
	return Vector2.ZERO


func refresh_y_level(y_level: int):
	for pos in tiles.keys():
		if pos.y == y_level:
			update_tile_mesh(pos)
	for pos in tiles.keys():
		if pos.y == y_level + 1 or pos.y == y_level - 1:
			update_tile_mesh(pos)
