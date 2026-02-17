class_name ProceduralStairsGenerator extends RefCounted

# CRITICAL: cube_bulge.obj has bounding box of 1.2 (widest dimension)
# After align_mesh_to_grid, it's scaled to fit grid_size
# Actual cube height = (1.000521 / 1.2) * grid_size ≈ 0.8338 * grid_size
const CUBE_HEIGHT_RATIO = 0.8338  # Actual ratio after scaling

static func generate_stairs_mesh(
	num_steps: int = 4,
	grid_size: float = 1.0,
	direction: int = 2  # Default: South-facing (steps ascend toward +Z, entry from -Z)
) -> ArrayMesh:
	
	# Match the actual scaled height of cube_bulge.obj
	var actual_height = grid_size * CUBE_HEIGHT_RATIO
	var step_height = actual_height / float(num_steps)
	var step_depth = grid_size / float(num_steps)
	var step_width = grid_size
	
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	var indices = PackedInt32Array()
	
	var vertex_index = 0
	
	for step in num_steps:
		var bottom = float(step) * step_height
		var top = float(step + 1) * step_height
		var front = float(step) * step_depth
		var back = float(step + 1) * step_depth
		
		var left = 0.0
		var right = step_width
		
		# Front face
		vertex_index = _add_quad(
			vertices, normals, uvs, indices, vertex_index,
			Vector3(left, bottom, front),
			Vector3(right, bottom, front),
			Vector3(right, top, front),
			Vector3(left, top, front),
			Vector3(0, 0, -1)
		)
		
		# Top face
		vertex_index = _add_quad(
			vertices, normals, uvs, indices, vertex_index,
			Vector3(left, top, front),
			Vector3(right, top, front),
			Vector3(right, top, back),
			Vector3(left, top, back),
			Vector3(0, 1, 0)
		)
		
		# Left side
		vertex_index = _add_quad(
			vertices, normals, uvs, indices, vertex_index,
			Vector3(left, 0, front),
			Vector3(left, 0, back),
			Vector3(left, top, back),
			Vector3(left, top, front),
			Vector3(-1, 0, 0)
		)
		
		# Right side
		vertex_index = _add_quad(
			vertices, normals, uvs, indices, vertex_index,
			Vector3(right, 0, front),
			Vector3(right, top, front),
			Vector3(right, top, back),
			Vector3(right, 0, back),
			Vector3(1, 0, 0)
		)
		
		# Back face (last step only)
		if step == num_steps - 1:
			vertex_index = _add_quad(
				vertices, normals, uvs, indices, vertex_index,
				Vector3(left, 0, back),
				Vector3(left, top, back),
				Vector3(right, top, back),
				Vector3(right, 0, back),
				Vector3(0, 0, 1)
			)
	
	if direction != 0:
		var rotation_angle = direction * 90.0
		_rotate_vertices(vertices, normals, rotation_angle, grid_size)
	
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	return mesh


static func _add_quad(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	start_index: int,
	v1: Vector3, v2: Vector3, v3: Vector3, v4: Vector3,
	normal: Vector3
) -> int:
	vertices.append(v1)
	vertices.append(v2)
	vertices.append(v3)
	vertices.append(v4)
	
	for i in 4:
		normals.append(normal)
	
	uvs.append(Vector2(0, 0))
	uvs.append(Vector2(1, 0))
	uvs.append(Vector2(1, 1))
	uvs.append(Vector2(0, 1))
	
	indices.append(start_index)
	indices.append(start_index + 1)
	indices.append(start_index + 2)
	
	indices.append(start_index)
	indices.append(start_index + 2)
	indices.append(start_index + 3)
	
	return start_index + 4


static func _rotate_vertices(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	angle_degrees: float,
	grid_size: float
) -> void:
	var angle_rad = deg_to_rad(angle_degrees)
	var rotation = Quaternion(Vector3.UP, angle_rad)
	var center = Vector3(grid_size / 2.0, 0, grid_size / 2.0)
	
	for i in range(vertices.size()):
		var v = vertices[i]
		v = v - center
		v = rotation * v
		v = v + center
		vertices[i] = v
	
	for i in range(normals.size()):
		normals[i] = rotation * normals[i]
