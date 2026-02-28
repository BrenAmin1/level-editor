class_name SurfaceClassifier extends RefCounted

func add_triangle_to_surface(triangles_by_surface: Dictionary, v0: Vector3, v1: Vector3, v2: Vector3,
							   uvs: PackedVector2Array, i0: int, i1: int, i2: int,
							   rotated_normals: PackedVector3Array, original_normals: PackedVector3Array):
	# Use the ORIGINAL (unrotated) normals to determine surface type
	var avg_normal = (original_normals[i0] + original_normals[i1] + original_normals[i2]).normalized()
	
	var SurfaceRole = MeshGenerator.SurfaceRole
	var MeshArrays = MeshGenerator.MeshArrays
	
	var target_surface: int
	# Classify based on the original normal direction
	if avg_normal.y > 0.8:
		target_surface = SurfaceRole.TOP
	elif avg_normal.y < -0.8:
		target_surface = SurfaceRole.BOTTOM
	else:
		target_surface = SurfaceRole.SIDES
	
	var target = triangles_by_surface[target_surface]
	var start_idx = target[MeshArrays.VERTICES].size()
	
	target[MeshArrays.VERTICES].append(v0)
	target[MeshArrays.VERTICES].append(v1)
	target[MeshArrays.VERTICES].append(v2)
	
	# Store the ROTATED normals in the actual mesh
	target[MeshArrays.NORMALS].append(rotated_normals[i0])
	target[MeshArrays.NORMALS].append(rotated_normals[i1])
	target[MeshArrays.NORMALS].append(rotated_normals[i2])
	
	if uvs.size() > 0:
		target[MeshArrays.UVS].append(uvs[i0] if i0 < uvs.size() else Vector2.ZERO)
		target[MeshArrays.UVS].append(uvs[i1] if i1 < uvs.size() else Vector2.ZERO)
		target[MeshArrays.UVS].append(uvs[i2] if i2 < uvs.size() else Vector2.ZERO)
	
	target[MeshArrays.INDICES].append(start_idx)
	target[MeshArrays.INDICES].append(start_idx + 1)
	target[MeshArrays.INDICES].append(start_idx + 2)
