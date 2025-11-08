class_name SurfaceClassifier extends RefCounted

func add_triangle_to_surface(triangles_by_surface: Dictionary, v0: Vector3, v1: Vector3, v2: Vector3,
							   uvs: PackedVector2Array, i0: int, i1: int, i2: int,
							   original_normals: PackedVector3Array):
	var edge1 = v1 - v0
	var edge2 = v2 - v0
	var face_normal = edge1.cross(edge2).normalized()
	
	var SurfaceType = MeshGenerator.SurfaceType
	var MeshArrays = MeshGenerator.MeshArrays
	
	var target_surface: int
	if face_normal.y > 0.8:
		target_surface = SurfaceType.TOP
	elif face_normal.y < -0.8:
		target_surface = SurfaceType.BOTTOM
	else:
		target_surface = SurfaceType.SIDES
	
	var target = triangles_by_surface[target_surface]
	var start_idx = target[MeshArrays.VERTICES].size()
	
	target[MeshArrays.VERTICES].append(v0)
	target[MeshArrays.VERTICES].append(v1)
	target[MeshArrays.VERTICES].append(v2)
	
	target[MeshArrays.NORMALS].append(original_normals[i0])
	target[MeshArrays.NORMALS].append(original_normals[i1])
	target[MeshArrays.NORMALS].append(original_normals[i2])
	
	if uvs.size() > 0:
		target[MeshArrays.UVS].append(uvs[i0] if i0 < uvs.size() else Vector2.ZERO)
		target[MeshArrays.UVS].append(uvs[i1] if i1 < uvs.size() else Vector2.ZERO)
		target[MeshArrays.UVS].append(uvs[i2] if i2 < uvs.size() else Vector2.ZERO)
	
	target[MeshArrays.INDICES].append(start_idx)
	target[MeshArrays.INDICES].append(start_idx + 1)
	target[MeshArrays.INDICES].append(start_idx + 2)
