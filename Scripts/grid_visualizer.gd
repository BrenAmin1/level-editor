class_name GridVisualizer extends Node3D

var grid_mesh: MeshInstance3D
var grid_highlight: MeshInstance3D

var grid_size: float = 1.0
var grid_range: int = 100
var current_y_level: int = 0
var current_offset: Vector2 = Vector2.ZERO

signal level_changed(level : int, offset : Vector2)

func _ready():
	create_grid()
	create_grid_highlight()

func create_grid():
	if grid_mesh:
		grid_mesh.queue_free()
	
	grid_mesh = MeshInstance3D.new()
	var immediate_mesh: ImmediateMesh = ImmediateMesh.new()
	grid_mesh.mesh = immediate_mesh
	
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.3, 0.3, 0.3, 0.3)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	grid_mesh.material_override = material
	
	add_child(grid_mesh)
	
	update_grid_lines()

func update_grid_lines():
	if not grid_mesh:
		return
	
	var immediate_mesh: ImmediateMesh = ImmediateMesh.new()
	grid_mesh.mesh = immediate_mesh
	
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	var y: float = current_y_level * grid_size
	
	# Draw vertical lines only at current Y level
	for x in range(-grid_range, grid_range + 1):
		for z in range(-grid_range, grid_range + 1):
			var x_pos = x * grid_size + current_offset.x
			var z_pos = z * grid_size + current_offset.y
			
			# Short vertical line at this grid point
			immediate_mesh.surface_add_vertex(Vector3(x_pos, y, z_pos))
			immediate_mesh.surface_add_vertex(Vector3(x_pos, y + grid_size * 0.1, z_pos))
	
	immediate_mesh.surface_end()

func create_grid_highlight():
	grid_highlight = MeshInstance3D.new()
	var immediate_mesh = ImmediateMesh.new()
	grid_highlight.mesh = immediate_mesh
	
	get_tree().root.add_child.call_deferred(grid_highlight)
	
	update_grid_highlight()

func update_grid_highlight():
	if not grid_highlight:
		return
	
	var immediate_mesh: ImmediateMesh = ImmediateMesh.new()
	grid_highlight.mesh = immediate_mesh
	
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.3, 0.8, 0.3, 0.4)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	grid_highlight.material_override = material
	
	var y: float = current_y_level * grid_size
	var start: float = -grid_range * grid_size
	var end: float = grid_range * grid_size
	
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	# Draw highlighted grid at current Y level with offset
	for i in range(-grid_range, grid_range + 1):
		var offset = i * grid_size
		
		# Lines parallel to X axis
		immediate_mesh.surface_add_vertex(Vector3(start + current_offset.x, y, offset + current_offset.y))
		immediate_mesh.surface_add_vertex(Vector3(end + current_offset.x, y, offset + current_offset.y))
		
		# Lines parallel to Z axis
		immediate_mesh.surface_add_vertex(Vector3(offset + current_offset.x, y, start + current_offset.y))
		immediate_mesh.surface_add_vertex(Vector3(offset + current_offset.x, y, end + current_offset.y))
	
	immediate_mesh.surface_end()

func set_y_level(level: int):
	current_y_level = level
	update_grid_lines()
	update_grid_highlight()
	level_changed.emit(current_y_level)

func set_y_level_offset(level: int, offset: Vector2):
	current_y_level = level
	current_offset = Vector2(clamp(offset.x,0.0,0.99),clamp(offset.y,0.0,0.99))
	level_changed.emit(current_y_level)
	update_grid_lines()
	update_grid_highlight()
