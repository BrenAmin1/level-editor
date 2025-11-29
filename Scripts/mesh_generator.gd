class_name MeshGenerator extends RefCounted

# Surface type enum for proper material assignment
enum SurfaceType {
	TOP = 0,      # Top face (grass)
	SIDES = 1,    # Side faces (dirt)
	BOTTOM = 2    # Bottom face (dirt)
}

# Mesh array components enum
enum MeshArrays {
	VERTICES,
	NORMALS,
	UVS,
	INDICES
}

# Neighbor direction enum
enum NeighborDir {
	NORTH,
	SOUTH,
	EAST,
	WEST,
	UP,
	DOWN,
	DIAGONAL_NW,
	DIAGONAL_NE,
	DIAGONAL_SW,
	DIAGONAL_SE
}

# References to parent TileMap3D data
var custom_meshes: Dictionary
var tiles: Dictionary
var grid_size: float
var tile_map: TileMap3D

# Sub-components
var vertex_processor: VertexProcessor
var surface_classifier: SurfaceClassifier
var culling_manager: CullingManager
var rotation_handler: RotationHandler
var mesh_builder: MeshBuilder

func setup(tilemap: TileMap3D, meshes_ref: Dictionary, tiles_ref: Dictionary, grid_sz: float):
	tile_map = tilemap
	custom_meshes = meshes_ref
	tiles = tiles_ref
	grid_size = grid_sz
	
	# Initialize sub-components
	vertex_processor = VertexProcessor.new()
	vertex_processor.setup(tile_map, tiles, grid_size)
	
	surface_classifier = SurfaceClassifier.new()
	
	culling_manager = CullingManager.new()
	culling_manager.setup(tile_map, tiles, grid_size)
	
	rotation_handler = RotationHandler.new()
	rotation_handler.setup(grid_size)
	
	mesh_builder = MeshBuilder.new()
	mesh_builder.setup(tile_map)

func generate_custom_tile_mesh(pos: Vector3i, tile_type: int, neighbors: Dictionary, rotation_degrees: float = 0.0) -> ArrayMesh:
	if tile_type not in custom_meshes:
		return ArrayMesh.new()
	
	var base_mesh = custom_meshes[tile_type]
	
	
	# Initialize surface data
	var triangles_by_surface = _initialize_surface_arrays()
	
	# Rotate neighbors to match tile orientation for vertex extension
	var rotated_neighbors = _rotate_neighbors(neighbors, rotation_degrees)
	
	# Culling setup
	var has_block_above = rotated_neighbors[NeighborDir.UP] != -1
	var exposed_corners = culling_manager.find_exposed_corners(rotated_neighbors)
	var disable_all_culling = has_block_above
	
	# Process each surface with rotated neighbors but NO geometry rotation
	for surface_idx in range(base_mesh.get_surface_count()):
		_process_mesh_surface(base_mesh, surface_idx, pos, rotated_neighbors,
							  triangles_by_surface, exposed_corners, disable_all_culling)
	
	return mesh_builder.build_final_mesh(triangles_by_surface, tile_type, base_mesh)


func _rotate_neighbors(neighbors: Dictionary, rotation_degrees: float) -> Dictionary:
	"""Rotate neighbor dictionary to match tile rotation"""
	if rotation_degrees == 0.0:
		return neighbors
	
	# Normalize rotation to 0, 90, 180, 270
	var rot = int(round(rotation_degrees)) % 360
	if rot < 0:
		rot += 360
	
	var rotated = neighbors.duplicate()
	
	# Only rotate cardinal directions (not UP/DOWN)
	var north = neighbors[NeighborDir.NORTH]
	var south = neighbors[NeighborDir.SOUTH]
	var east = neighbors[NeighborDir.EAST]
	var west = neighbors[NeighborDir.WEST]
	
	match rot:
		90:  # Clockwise 90°
			rotated[NeighborDir.NORTH] = west
			rotated[NeighborDir.EAST] = north
			rotated[NeighborDir.SOUTH] = east
			rotated[NeighborDir.WEST] = south
		180:  # 180°
			rotated[NeighborDir.NORTH] = south
			rotated[NeighborDir.EAST] = west
			rotated[NeighborDir.SOUTH] = north
			rotated[NeighborDir.WEST] = east
		270:  # Counter-clockwise 90° (or clockwise 270°)
			rotated[NeighborDir.NORTH] = east
			rotated[NeighborDir.EAST] = south
			rotated[NeighborDir.SOUTH] = west
			rotated[NeighborDir.WEST] = north
	
	return rotated

func _initialize_surface_arrays() -> Dictionary:
	var triangles_by_surface = {}
	for surf_type in SurfaceType.values():
		triangles_by_surface[surf_type] = {
			MeshArrays.VERTICES: PackedVector3Array(),
			MeshArrays.NORMALS: PackedVector3Array(),
			MeshArrays.UVS: PackedVector2Array(),
			MeshArrays.INDICES: PackedInt32Array()
		}
	return triangles_by_surface

func _process_mesh_surface(base_mesh: ArrayMesh, surface_idx: int, pos: Vector3i, 
							neighbors: Dictionary, triangles_by_surface: Dictionary,
							exposed_corners: Array, disable_all_culling: bool):
	var arrays = base_mesh.surface_get_arrays(surface_idx)
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var normals = arrays[Mesh.ARRAY_NORMAL]
	var uvs = arrays[Mesh.ARRAY_TEX_UV]
	var indices = arrays[Mesh.ARRAY_INDEX]
	
	# Store ORIGINAL normals for classification
	var original_normals = normals
	
	# NOTE: rotation_angle is now 0 (no vertex rotation), but we pass rotation for extension logic
	var tile_rotation = 0.0
	if pos in tile_map.tile_rotations:
		tile_rotation = tile_map.tile_rotations[pos]
	
	# Process each triangle
	for i in range(0, indices.size(), 3):
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]
		
		var v0 = vertices[i0]
		var v1 = vertices[i1]
		var v2 = vertices[i2]
		
		var n0 = normals[i0]
		var n1 = normals[i1]
		var n2 = normals[i2]
		
		var face_normal = (n0 + n1 + n2).normalized()
		var face_center = (v0 + v1 + v2) / 3.0
		
		# Check culling
		if culling_manager.should_cull_triangle(pos, neighbors, face_center, face_normal, 
												exposed_corners, disable_all_culling):
			continue
		
		# Extend vertices to boundaries WITH rotation awareness
		v0 = vertex_processor.extend_to_boundary_if_neighbor_rotated(v0, neighbors, 0.35, pos, tile_rotation)
		v1 = vertex_processor.extend_to_boundary_if_neighbor_rotated(v1, neighbors, 0.35, pos, tile_rotation)
		v2 = vertex_processor.extend_to_boundary_if_neighbor_rotated(v2, neighbors, 0.35, pos, tile_rotation)
		
		# Add to surface
		surface_classifier.add_triangle_to_surface(triangles_by_surface, v0, v1, v2, uvs, i0, i1, i2, normals, original_normals)

func generate_tile_mesh(tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	return mesh_builder.generate_simple_tile_mesh(tile_type, neighbors, grid_size)
