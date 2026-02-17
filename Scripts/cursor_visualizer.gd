class_name CursorVisualizer extends Node3D

var cursor_preview: MeshInstance3D
var cursor_outline: MeshInstance3D
var intersection_marker: MeshInstance3D

var grid_size: float = 1.0

# Set these each frame from LevelEditor before calling update_cursor_with_offset
var current_tile_type: int = 0
var current_rotation: float = 0.0
var current_step_count: int = 4

# Cache to avoid rebuilding the preview mesh every frame
var _last_tile_type: int = -1
var _last_rotation: float = -1.0
var _last_step_count: int = -1

const TILE_TYPE_STAIRS = 5

func _ready():
	create_cursor_preview()
	create_cursor_outline()
	create_intersection_marker()

func create_cursor_preview():
	cursor_preview = MeshInstance3D.new()
	
	var box_mesh: ArrayMesh = create_box_mesh(grid_size)
	cursor_preview.mesh = box_mesh
	
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 1.0, 0.0, 0.3)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	cursor_preview.material_override = material
	
	cursor_preview.visible = false
	add_child(cursor_preview)

func create_cursor_outline():
	cursor_outline = MeshInstance3D.new()
	
	var immediate_mesh: ImmediateMesh = ImmediateMesh.new()
	cursor_outline.mesh = immediate_mesh
	
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.8)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	cursor_outline.material_override = material
	
	cursor_outline.visible = false
	add_child(cursor_outline)

func create_intersection_marker():
	intersection_marker = MeshInstance3D.new()
	var sphere_mesh: SphereMesh = SphereMesh.new()
	sphere_mesh.radius = 0.1
	sphere_mesh.height = 0.2
	intersection_marker.mesh = sphere_mesh
	
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.0, 1.0, 1.0)
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	intersection_marker.material_override = material
	
	intersection_marker.visible = false
	add_child(intersection_marker)

func update_cursor(camera: Camera3D, current_y_level: int, tile_exists: bool):
	update_cursor_with_offset(camera, current_y_level, tile_exists, Vector2.ZERO)

func update_cursor_with_offset(camera: Camera3D, current_y_level: int, tile_exists: bool, offset: Vector2):
	if not camera:
		cursor_preview.visible = false
		cursor_outline.visible = false
		return
	
	var viewport = camera.get_viewport()
	if not viewport:
		cursor_preview.visible = false
		cursor_outline.visible = false
		return
	
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var to: Vector3 = from + camera.project_ray_normal(mouse_pos) * 1000
	
	# Create a plane at the current Y level
	var y_world: float = current_y_level * grid_size
	var placement_plane: Plane = Plane(Vector3.UP, y_world)
	var intersection = placement_plane.intersects_ray(from, to - from)
	
	if intersection:
		var adjusted_intersection = intersection - Vector3(offset.x, 0, offset.y)
		
		var grid_pos = Vector3i(
			floori(adjusted_intersection.x / grid_size),
			current_y_level,
			floori(adjusted_intersection.z / grid_size)
		)
		
		# Rebuild preview mesh if tile type / rotation / step count changed
		_refresh_cursor_mesh()
		
		# Update outline for hovered cell
		update_cursor_outline(grid_pos, offset)
		
		# Show preview at this position
		cursor_preview.visible = true
		cursor_preview.position = grid_to_world(grid_pos, offset)
		
		# Change color based on whether tile exists
		var material: StandardMaterial3D = cursor_preview.material_override as StandardMaterial3D
		if material:
			if tile_exists:
				material.albedo_color = Color(1.0, 0.0, 0.0, 0.5)
			else:
				material.albedo_color = Color(0.0, 1.0, 0.0, 0.5)
	else:
		cursor_preview.visible = false
		cursor_outline.visible = false

func _refresh_cursor_mesh() -> void:
	# Only rebuild when something actually changed
	if (current_tile_type == _last_tile_type
			and current_rotation == _last_rotation
			and current_step_count == _last_step_count):
		return
	_last_tile_type = current_tile_type
	_last_rotation = current_rotation
	_last_step_count = current_step_count

	if current_tile_type == TILE_TYPE_STAIRS:
		cursor_preview.mesh = _build_stair_mesh()
	else:
		cursor_preview.mesh = create_box_mesh(grid_size)


func _build_stair_mesh() -> ArrayMesh:
	# Map rotation degrees to the direction int used by ProceduralStairsGenerator
	var normalized = int(round(current_rotation)) % 360
	if normalized < 0:
		normalized += 360
	var direction = 0
	match normalized:
		0:   direction = 0
		90:  direction = 1
		180: direction = 2
		270: direction = 3
	return ProceduralStairsGenerator.generate_stairs_mesh(current_step_count, grid_size, direction)


func update_cursor_outline(grid_pos: Vector3i, offset: Vector2):
	if not cursor_outline:
		return
	
	var immediate_mesh: ImmediateMesh = ImmediateMesh.new()
	cursor_outline.mesh = immediate_mesh
	
	var s: float = grid_size
	var pos: Vector3 = grid_to_world(grid_pos, offset)
	
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	# Bottom square
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, 0))
	
	# Top square
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, 0))
	
	# Vertical edges
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, s))
	
	immediate_mesh.surface_end()
	
	cursor_outline.visible = true

func grid_to_world(pos: Vector3i, offset: Vector2 = Vector2.ZERO) -> Vector3:
	return Vector3(pos.x * grid_size + offset.x, pos.y * grid_size, pos.z * grid_size + offset.y)

func create_box_mesh(size: float) -> ArrayMesh:
	var surface_array: Array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	
	var s: float = size
	
	# Front face (Z-)
	add_quad(verts, indices, normals, uvs,
		Vector3(0, 0, 0), Vector3(s, 0, 0),
		Vector3(s, s, 0), Vector3(0, s, 0),
		Vector3(0, 0, -1))
	
	# Back face (Z+)
	add_quad(verts, indices, normals, uvs,
		Vector3(s, 0, s), Vector3(0, 0, s),
		Vector3(0, s, s), Vector3(s, s, s),
		Vector3(0, 0, 1))
	
	# Right face (X+)
	add_quad(verts, indices, normals, uvs,
		Vector3(s, 0, 0), Vector3(s, 0, s),
		Vector3(s, s, s), Vector3(s, s, 0),
		Vector3(1, 0, 0))
	
	# Left face (X-)
	add_quad(verts, indices, normals, uvs,
		Vector3(0, 0, s), Vector3(0, 0, 0),
		Vector3(0, s, 0), Vector3(0, s, s),
		Vector3(-1, 0, 0))
	
	# Top face (Y+)
	add_quad(verts, indices, normals, uvs,
		Vector3(0, s, 0), Vector3(s, s, 0),
		Vector3(s, s, s), Vector3(0, s, s),
		Vector3(0, 1, 0))

	surface_array[Mesh.ARRAY_VERTEX] = verts
	surface_array[Mesh.ARRAY_INDEX] = indices
	surface_array[Mesh.ARRAY_NORMAL] = normals
	surface_array[Mesh.ARRAY_TEX_UV] = uvs
	
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
	
	return mesh

func add_quad(verts: PackedVector3Array, indices: PackedInt32Array,
			  normals: PackedVector3Array, uvs: PackedVector2Array,
			  v1: Vector3, v2: Vector3, v3: Vector3, v4: Vector3, normal: Vector3):
	var start: int = verts.size()
	
	verts.append_array([v1, v2, v3, v4])
	normals.append_array([normal, normal, normal, normal])
	uvs.append_array([
		Vector2(0, 1), Vector2(1, 1),
		Vector2(1, 0), Vector2(0, 0)
	])
	
	indices.append_array([
		start, start + 1, start + 2,
		start, start + 2, start + 3
	])
