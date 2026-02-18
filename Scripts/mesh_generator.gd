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

# Tile type constants - ADD STAIRS HERE
const TILE_TYPE_STAIRS = 5  # New tile type for procedural stairs

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


func generate_custom_tile_mesh(pos: Vector3i, tile_type: int, neighbors: Dictionary, rotation_degrees: float = 0.0, is_fully_enclosed: bool = false, step_count: int = 4) -> ArrayMesh:
	# CHECK IF STAIRS - Generate geometry procedurally, then cull side/back faces
	if tile_type == TILE_TYPE_STAIRS:
		return _generate_procedural_stairs_culled(rotation_degrees, step_count, neighbors)
	
	if tile_type not in custom_meshes:
		return ArrayMesh.new()
	
	var base_mesh = custom_meshes[tile_type]
	
	
	# Initialize surface data
	var triangles_by_surface = _initialize_surface_arrays()
	
	# Rotate neighbors to match tile orientation for vertex extension
	var rotated_neighbors = _rotate_neighbors(neighbors, rotation_degrees)
	
	# Culling setup
	var has_block_above = rotated_neighbors[NeighborDir.UP] != -1 and rotated_neighbors[NeighborDir.UP] != TILE_TYPE_STAIRS
	var exposed_corners = culling_manager.find_exposed_corners(rotated_neighbors)
	var disable_all_culling = has_block_above
	
	# Process each surface with rotated neighbors but NO geometry rotation
	for surface_idx in range(base_mesh.get_surface_count()):
		_process_mesh_surface(base_mesh, surface_idx, pos, rotated_neighbors,
							  triangles_by_surface, exposed_corners, disable_all_culling, is_fully_enclosed)
	
	return mesh_builder.build_final_mesh(triangles_by_surface, tile_type, base_mesh)


# Generate procedural stairs based on rotation and step count, with neighbor culling
func _generate_procedural_stairs_culled(rotation_degrees: float, num_steps: int, neighbors: Dictionary) -> ArrayMesh:
	# Get the raw stair mesh (all faces present)
	var raw_mesh = _generate_procedural_stairs(rotation_degrees, num_steps)
	if raw_mesh.get_surface_count() == 0:
		return raw_mesh

	var arrays = raw_mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var new_verts = PackedVector3Array()
	var new_normals = PackedVector3Array()
	var new_uvs = PackedVector2Array()
	var new_indices = PackedInt32Array()
	var next_index = 0

	for i in range(0, indices.size(), 3):
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]

		var n0 = normals[i0]
		var n1 = normals[i1]
		var n2 = normals[i2]
		var face_normal = (n0 + n1 + n2).normalized()

		# Ask culling manager whether this triangle should be dropped
		if culling_manager.should_cull_stair_face(face_normal, neighbors, rotation_degrees):
			continue

		new_verts.append(vertices[i0])
		new_verts.append(vertices[i1])
		new_verts.append(vertices[i2])
		new_normals.append(n0)
		new_normals.append(n1)
		new_normals.append(n2)
		new_uvs.append(uvs[i0])
		new_uvs.append(uvs[i1])
		new_uvs.append(uvs[i2])
		new_indices.append(next_index)
		new_indices.append(next_index + 1)
		new_indices.append(next_index + 2)
		next_index += 3

	if new_verts.is_empty():
		return ArrayMesh.new()

	var out_arrays = []
	out_arrays.resize(Mesh.ARRAY_MAX)
	out_arrays[Mesh.ARRAY_VERTEX] = new_verts
	out_arrays[Mesh.ARRAY_NORMAL] = new_normals
	out_arrays[Mesh.ARRAY_TEX_UV] = new_uvs
	out_arrays[Mesh.ARRAY_INDEX] = new_indices

	var result = ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arrays)
	return result


# Generate procedural stairs based on rotation and step count
func _generate_procedural_stairs(rotation_degrees: float, num_steps: int = 4) -> ArrayMesh:
	return ProceduralStairsGenerator.generate_stairs_mesh(num_steps, grid_size, rotation_degrees)


func _rotate_neighbors(neighbors: Dictionary, rotation_degrees: float) -> Dictionary:
	"""Rotate neighbor dictionary to match tile rotation"""
	if rotation_degrees == 0.0:
		return neighbors
	
	# Normalize rotation to 0, 90, 180, 270
	var rot = int(round(rotation_degrees)) % 360
	if rot < 0:
		rot += 360
	
	var rotated = neighbors.duplicate()
	
	# Get all neighbor values
	var north = neighbors[NeighborDir.NORTH]
	var south = neighbors[NeighborDir.SOUTH]
	var east = neighbors[NeighborDir.EAST]
	var west = neighbors[NeighborDir.WEST]
	
	# Get diagonal neighbors (with safe defaults)
	var nw = neighbors.get(NeighborDir.DIAGONAL_NW, -1)
	var ne = neighbors.get(NeighborDir.DIAGONAL_NE, -1)
	var sw = neighbors.get(NeighborDir.DIAGONAL_SW, -1)
	var se = neighbors.get(NeighborDir.DIAGONAL_SE, -1)
	
	match rot:
		90:  # Clockwise 90°
			rotated[NeighborDir.NORTH] = west
			rotated[NeighborDir.EAST] = north
			rotated[NeighborDir.SOUTH] = east
			rotated[NeighborDir.WEST] = south
			# Rotate diagonals: NW->NE, NE->SE, SE->SW, SW->NW
			rotated[NeighborDir.DIAGONAL_NE] = nw
			rotated[NeighborDir.DIAGONAL_SE] = ne
			rotated[NeighborDir.DIAGONAL_SW] = se
			rotated[NeighborDir.DIAGONAL_NW] = sw
		180:  # 180°
			rotated[NeighborDir.NORTH] = south
			rotated[NeighborDir.EAST] = west
			rotated[NeighborDir.SOUTH] = north
			rotated[NeighborDir.WEST] = east
			# Rotate diagonals: NW->SE, NE->SW, SE->NW, SW->NE
			rotated[NeighborDir.DIAGONAL_SE] = nw
			rotated[NeighborDir.DIAGONAL_SW] = ne
			rotated[NeighborDir.DIAGONAL_NW] = se
			rotated[NeighborDir.DIAGONAL_NE] = sw
		270:  # Counter-clockwise 90° (or clockwise 270°)
			rotated[NeighborDir.NORTH] = east
			rotated[NeighborDir.EAST] = south
			rotated[NeighborDir.SOUTH] = west
			rotated[NeighborDir.WEST] = north
			# Rotate diagonals: NW->SW, SW->SE, SE->NE, NE->NW
			rotated[NeighborDir.DIAGONAL_SW] = nw
			rotated[NeighborDir.DIAGONAL_SE] = sw
			rotated[NeighborDir.DIAGONAL_NE] = se
			rotated[NeighborDir.DIAGONAL_NW] = ne
	
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
							exposed_corners: Array, disable_all_culling: bool, is_fully_enclosed: bool = false):
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
		
		# Check culling - pass pre-captured is_fully_enclosed
		if culling_manager.should_cull_triangle(pos, neighbors, face_center, face_normal, 
												exposed_corners, disable_all_culling, is_fully_enclosed):
			continue
		
		# Extend vertices to boundaries WITH rotation awareness
		v0 = vertex_processor.extend_to_boundary_if_neighbor_rotated(v0, neighbors, 0.35, pos, tile_rotation)
		v1 = vertex_processor.extend_to_boundary_if_neighbor_rotated(v1, neighbors, 0.35, pos, tile_rotation)
		v2 = vertex_processor.extend_to_boundary_if_neighbor_rotated(v2, neighbors, 0.35, pos, tile_rotation)
		
		# Add to surface
		surface_classifier.add_triangle_to_surface(triangles_by_surface, v0, v1, v2, uvs, i0, i1, i2, normals, original_normals)

func generate_tile_mesh(tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	# CHECK IF STAIRS - Handle procedurally with default rotation (South-facing)
	if tile_type == TILE_TYPE_STAIRS:
		return ProceduralStairsGenerator.generate_stairs_mesh(4, grid_size, 180)
	
	return mesh_builder.generate_simple_tile_mesh(tile_type, neighbors, grid_size)
