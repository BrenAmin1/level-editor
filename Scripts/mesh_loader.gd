class_name MeshLoader extends RefCounted

# References to parent TileMap3D data and components
var custom_meshes: Dictionary  # Reference to TileMap3D.custom_meshes
var custom_materials: Dictionary  # Reference to TileMap3D.custom_materials
var grid_size: float  # Reference to TileMap3D.grid_size
var mesh_editor: MeshEditor  # Reference to MeshEditor component

# ============================================================================
# SETUP
# ============================================================================

func setup(meshes_ref: Dictionary, materials_ref: Dictionary, grid_sz: float, editor: MeshEditor):
	custom_meshes = meshes_ref
	custom_materials = materials_ref
	grid_size = grid_sz
	mesh_editor = editor

# ============================================================================
# MESH LOADING FUNCTIONS
# ============================================================================

# Load an OBJ file and associate it with a tile type (supports multiple materials via usemtl groups)
func load_obj_for_tile_type(tile_type: int, obj_path: String) -> bool:
	var file = FileAccess.open(obj_path, FileAccess.READ)
	if not file:
		push_error("Failed to open OBJ file: " + obj_path)
		return false
	
	var temp_vertices = []
	var temp_normals = []
	var temp_uvs = []
	var material_groups = {}  # material_name -> faces
	var current_material = "default"
	
	while not file.eof_reached():
		var line = file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		
		var parts = line.split(" ", false)
		if parts.size() == 0:
			continue
		
		match parts[0]:
			"v":  # Vertex
				if parts.size() >= 4:
					temp_vertices.append(Vector3(
						parts[1].to_float(),
						parts[2].to_float(),
						parts[3].to_float()
					))
			"vn":  # Normal
				if parts.size() >= 4:
					temp_normals.append(Vector3(
						parts[1].to_float(),
						parts[2].to_float(),
						parts[3].to_float()
					))
			"vt":  # UV
				if parts.size() >= 3:
					temp_uvs.append(Vector2(
						parts[1].to_float(),
						parts[2].to_float()
					))
			"usemtl":  # Material assignment
				if parts.size() >= 2:
					current_material = parts[1]
					if current_material not in material_groups:
						material_groups[current_material] = []
			"f":  # Face
				var face = []
				for i in range(1, parts.size()):
					var indices = parts[i].split("/")
					var vert_idx = indices[0].to_int() - 1
					var uv_idx = indices[1].to_int() - 1 if indices.size() > 1 and indices[1] != "" else -1
					var norm_idx = indices[2].to_int() - 1 if indices.size() > 2 else -1
					face.append({"v": vert_idx, "vt": uv_idx, "vn": norm_idx})
				
				# Add face to current material group
				if current_material not in material_groups:
					material_groups[current_material] = []
				material_groups[current_material].append(face)
	
	file.close()
	
	# Create mesh with multiple surfaces (one per material)
	var mesh = ArrayMesh.new()
	var materials_array = []
	
	print("Loading mesh with ", material_groups.size(), " material groups: ", material_groups.keys())
	
	for mat_name in material_groups:
		var faces = material_groups[mat_name]
		
		# Convert faces to triangles
		var final_verts = PackedVector3Array()
		var final_normals = PackedVector3Array()
		var final_uvs = PackedVector2Array()
		var final_indices = PackedInt32Array()
		
		for face in faces:
			# Triangulate face (simple fan triangulation)
			for i in range(1, face.size() - 1):
				for idx in [0, i, i + 1]:
					var face_vert = face[idx]
					final_verts.append(temp_vertices[face_vert.v])
					
					if face_vert.vn >= 0 and face_vert.vn < temp_normals.size():
						final_normals.append(temp_normals[face_vert.vn])
					else:
						final_normals.append(Vector3.UP)
					
					if face_vert.vt >= 0 and face_vert.vt < temp_uvs.size():
						final_uvs.append(temp_uvs[face_vert.vt])
					else:
						final_uvs.append(Vector2.ZERO)
		
		# Create indices
		for i in range(final_verts.size()):
			final_indices.append(i)
		
		# Create surface for this material group
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = final_verts
		surface_array[Mesh.ARRAY_NORMAL] = final_normals
		surface_array[Mesh.ARRAY_TEX_UV] = final_uvs
		surface_array[Mesh.ARRAY_INDEX] = final_indices
		
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		
		# Create default material for this surface
		var material = StandardMaterial3D.new()
		material.albedo_color = Color.WHITE
		material.cull_mode = BaseMaterial3D.CULL_BACK
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
		materials_array.append(material)
		
		print("  Surface ", mesh.get_surface_count() - 1, ": ", mat_name, " (", faces.size(), " faces)")
	
	custom_meshes[tile_type] = mesh
	custom_materials[tile_type] = materials_array  # Store array of materials
	
	print("✓ Loaded mesh for tile type ", tile_type, " with ", mesh.get_surface_count(), " surfaces")
	
	# Fix Blender's inverted normals and winding order (handles multiple surfaces)
	flip_mesh_normals(tile_type)
	
	# Auto-position and scale the mesh to fit grid (handles multiple surfaces)
	align_mesh_to_grid(tile_type)
	
	return true


# Extend boundary vertices to grid edges (fixes gaps from bevels)
func extend_mesh_to_boundaries(tile_type: int, threshold: float = 0.15) -> bool:
	var mesh_data = mesh_editor.get_mesh_data(tile_type)
	if mesh_data.is_empty():
		return false
	
	var vertices = mesh_data.vertices
	var s = grid_size
	
	for i in range(vertices.size()):
		var v = vertices[i]
		
		# Snap vertices close to boundaries to exact boundaries
		if v.x < threshold:
			v.x = 0
		elif v.x > s - threshold:
			v.x = s
			
		if v.y < threshold:
			v.y = -0.5
		elif v.y > s - threshold:
			v.y = s
			
		if v.z < threshold:
			v.z = 0
		elif v.z > s - threshold:
			v.z = s
		
		vertices[i] = v
	
	return mesh_editor.edit_mesh_vertices(tile_type, vertices)


# Replace the flip_mesh_normals function in mesh_loader.gd:

# Flip normals and reverse winding order for Blender meshes (handles multiple surfaces)
# ONLY flips normals that are pointing downward (negative Y) - keeps top faces correct
func flip_mesh_normals(tile_type: int) -> bool:
	if tile_type not in custom_meshes:
		return false
	
	var mesh = custom_meshes[tile_type]
	var new_mesh = ArrayMesh.new()
	
	# Process each surface
	for surface_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var indices = arrays[Mesh.ARRAY_INDEX]
		
		# Calculate face normals to determine if we should flip
		# Process per triangle to be selective
		for i in range(0, indices.size(), 3):
			var i0 = indices[i]
			var i1 = indices[i + 1]
			var i2 = indices[i + 2]
			
			var v0 = vertices[i0]
			var v1 = vertices[i1]
			var v2 = vertices[i2]
			
			# Calculate face normal from vertices (this is the "true" direction)
			var edge1 = v1 - v0
			var edge2 = v2 - v0
			var face_normal = edge1.cross(edge2).normalized()
			
			# Check average vertex normal direction
			var avg_normal = (normals[i0] + normals[i1] + normals[i2]).normalized()
			
			# If vertex normals point opposite to face normal, flip them
			if face_normal.dot(avg_normal) < 0:
				normals[i0] = -normals[i0]
				normals[i1] = -normals[i1]
				normals[i2] = -normals[i2]
		
		# Always reverse winding order for Blender coordinate system
		for i in range(0, indices.size(), 3):
			var temp = indices[i + 1]
			indices[i + 1] = indices[i + 2]
			indices[i + 2] = temp
		
		# Create new surface
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = vertices
		surface_array[Mesh.ARRAY_NORMAL] = normals
		surface_array[Mesh.ARRAY_TEX_UV] = uvs
		surface_array[Mesh.ARRAY_INDEX] = indices
		
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		new_mesh.surface_set_material(surface_idx, mesh.surface_get_material(surface_idx))
	
	custom_meshes[tile_type] = new_mesh
	return true


# Align mesh to grid cell (bottom-left corner at origin) - handles multiple surfaces
func align_mesh_to_grid(tile_type: int) -> bool:
	if tile_type not in custom_meshes:
		return false
	
	var mesh = custom_meshes[tile_type]
	
	# Calculate bounding box across ALL surfaces
	var min_bounds = Vector3.ZERO
	var max_bounds = Vector3.ZERO
	var first_vertex = true
	
	for surface_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		
		for v in vertices:
			if first_vertex:
				min_bounds = v
				max_bounds = v
				first_vertex = false
			else:
				min_bounds.x = min(min_bounds.x, v.x)
				min_bounds.y = min(min_bounds.y, v.y)
				min_bounds.z = min(min_bounds.z, v.z)
				max_bounds.x = max(max_bounds.x, v.x)
				max_bounds.y = max(max_bounds.y, v.y)
				max_bounds.z = max(max_bounds.z, v.z)
	
	var size = max_bounds - min_bounds

	# Uniform scale preserves mesh proportions as designed in Blender
	var max_dimension = max(size.x, max(size.y, size.z))
	var scale_factor = grid_size / max_dimension if max_dimension > 0 else 1.0

	# Transform all surfaces — offset to origin, then scale to fit grid
	var new_mesh = ArrayMesh.new()

	for surface_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX].duplicate()
		for i in range(vertices.size()):
			vertices[i] = (vertices[i] - min_bounds) * scale_factor

		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = vertices
		surface_array[Mesh.ARRAY_NORMAL] = arrays[Mesh.ARRAY_NORMAL]
		surface_array[Mesh.ARRAY_TEX_UV] = arrays[Mesh.ARRAY_TEX_UV]
		surface_array[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]

		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		new_mesh.surface_set_material(surface_idx, mesh.surface_get_material(surface_idx))

	custom_meshes[tile_type] = new_mesh
	return true
