extends PopupPanel

# References to UI elements
@onready var preview_rect: TextureRect = %Preview
@onready var material_name_input: LineEdit = %LineEdit
@onready var save_button: Button = %SaveButton
@onready var cancel_button: Button = %CancelButton

# Texture selection buttons
@onready var top_texture_btn: Button = %TopTextureBtn
@onready var top_normal_btn: Button = %TopNormalBtn
@onready var side_texture_btn: Button = %SideTextureBtn
@onready var side_normal_btn: Button = %SideNormalBtn
@onready var bottom_texture_btn: Button = %BottomTextureBtn
@onready var bottom_normal_btn: Button = %BottomNormalBtn

# 3D Preview
@onready var preview_viewport: SubViewport
@onready var preview_camera: Camera3D
@onready var preview_mesh: MeshInstance3D

# Material data
var material_data := {
	"name": "",
	"top_texture": "",
	"top_normal": "",
	"side_texture": "",
	"side_normal": "",
	"bottom_texture": "",
	"bottom_normal": ""
}

# File dialog for texture selection
var file_dialog: FileDialog
var current_texture_type := ""

# EDIT MODE TRACKING
var is_editing: bool = false
var editing_index: int = -1

signal material_created(material_dict: Dictionary)
signal material_edited(index: int, material_dict: Dictionary)  # NEW SIGNAL
signal popup_opened()
signal popup_closed()

func _ready() -> void:
	# Prevent popup from closing when clicking outside or losing focus
	set_flag(Window.FLAG_POPUP, false)
	
	# Connect button signals
	save_button.pressed.connect(_on_save_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)
	
	# Connect texture selection buttons
	top_texture_btn.pressed.connect(_on_texture_button_pressed.bind("top_texture"))
	top_normal_btn.pressed.connect(_on_texture_button_pressed.bind("top_normal"))
	side_texture_btn.pressed.connect(_on_texture_button_pressed.bind("side_texture"))
	side_normal_btn.pressed.connect(_on_texture_button_pressed.bind("side_normal"))
	bottom_texture_btn.pressed.connect(_on_texture_button_pressed.bind("bottom_texture"))
	bottom_normal_btn.pressed.connect(_on_texture_button_pressed.bind("bottom_normal"))
	
	# Setup file dialog
	_setup_file_dialog()
	
	# Setup 3D preview asynchronously to avoid startup lag
	_setup_3d_preview_async()
	
	# Connect to popup signals
	popup_hide.connect(_on_popup_hide)
	about_to_popup.connect(_on_about_to_popup)
	var level_editor = get_tree().current_scene
	if level_editor and level_editor.has_node("InputHandler"):
		var input_handler = level_editor.input_handler
		input_handler.register_focus_control(material_name_input)

func _setup_file_dialog() -> void:
	file_dialog = FileDialog.new()
	add_child(file_dialog)
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg ; Image Files"])
	file_dialog.use_native_dialog = true
	file_dialog.file_selected.connect(_on_file_selected)
	
	# Prevent popup from closing when file dialog opens
	set_exclusive(false)


func _setup_3d_preview_async() -> void:
	"""Async version: defers heavy work to avoid blocking startup"""
	call_deferred("_setup_3d_preview")


func _setup_3d_preview() -> void:
	"""Setup 3D preview - now called deferred to not block startup"""
	# Create SubViewport for 3D rendering with its own isolated world
	preview_viewport = SubViewport.new()
	preview_viewport.size = Vector2i(160, 160)
	preview_viewport.transparent_bg = true
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	preview_viewport.own_world_3d = true
	add_child(preview_viewport)
	
	# Create camera
	preview_camera = Camera3D.new()
	var cam_pos = Vector3(1.5, 1.5, 1.5)
	var look_target = Vector3(0.5, 0.5, 0.5)
	preview_camera.look_at_from_position(cam_pos, look_target, Vector3.UP)
	preview_viewport.add_child(preview_camera)
	
	# Create light
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	light.light_energy = 1.0
	preview_viewport.add_child(light)
	
	# Add environment for better lighting
	var environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.2, 0.2, 0.2, 0.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.4, 0.4, 0.4)
	var world_env = WorldEnvironment.new()
	world_env.environment = environment
	preview_viewport.add_child(world_env)
	
	# Load cube_bulge.obj and RECLASSIFY triangles by normal direction
	var mesh_resource := load("res://cubes/cube_bulge.obj")
	if mesh_resource:
		var reclassified_mesh = _reclassify_mesh_by_normals(mesh_resource)
		
		preview_mesh = MeshInstance3D.new()
		preview_mesh.mesh = reclassified_mesh
		preview_viewport.add_child(preview_mesh)
		
		_update_preview_material()
	else:
		push_error("Failed to load cube_bulge.obj")
	
	# Set viewport texture to preview rect
	preview_rect.texture = preview_viewport.get_texture()
	
	# Enable mouse input on the preview rect for rotation
	preview_rect.gui_input.connect(_on_preview_input)


func _reclassify_mesh_by_normals(source_mesh: ArrayMesh) -> ArrayMesh:
	"""Reclassify mesh triangles by normal direction, matching the tilemap's SurfaceClassifier logic"""
	
	# Initialize arrays for each surface type
	var top_verts = PackedVector3Array()
	var top_normals = PackedVector3Array()
	var top_uvs = PackedVector2Array()
	var top_indices = PackedInt32Array()
	
	var sides_verts = PackedVector3Array()
	var sides_normals = PackedVector3Array()
	var sides_uvs = PackedVector2Array()
	var sides_indices = PackedInt32Array()
	
	var bottom_verts = PackedVector3Array()
	var bottom_normals = PackedVector3Array()
	var bottom_uvs = PackedVector2Array()
	var bottom_indices = PackedInt32Array()
	
	# Process all surfaces from the source mesh
	for surf_idx in range(source_mesh.get_surface_count()):
		var arrays = source_mesh.surface_get_arrays(surf_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var indices = arrays[Mesh.ARRAY_INDEX]
		
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
			
			# Safe UV handling
			var uv0 = Vector2.ZERO
			var uv1 = Vector2.ZERO
			var uv2 = Vector2.ZERO
			if uvs != null and uvs.size() > 0:
				uv0 = uvs[i0] if i0 < uvs.size() else Vector2.ZERO
				uv1 = uvs[i1] if i1 < uvs.size() else Vector2.ZERO
				uv2 = uvs[i2] if i2 < uvs.size() else Vector2.ZERO
			
			# Calculate average normal
			var avg_normal = (n0 + n1 + n2).normalized()
			
			# Classify based on Y component
			if avg_normal.y > 0.8:
				# TOP surface
				var start_idx = top_verts.size()
				top_verts.append(v0)
				top_verts.append(v1)
				top_verts.append(v2)
				top_normals.append(n0)
				top_normals.append(n1)
				top_normals.append(n2)
				top_uvs.append(uv0)
				top_uvs.append(uv1)
				top_uvs.append(uv2)
				top_indices.append(start_idx)
				top_indices.append(start_idx + 1)
				top_indices.append(start_idx + 2)
			elif avg_normal.y < -0.8:
				# BOTTOM surface
				var start_idx = bottom_verts.size()
				bottom_verts.append(v0)
				bottom_verts.append(v1)
				bottom_verts.append(v2)
				bottom_normals.append(n0)
				bottom_normals.append(n1)
				bottom_normals.append(n2)
				bottom_uvs.append(uv0)
				bottom_uvs.append(uv1)
				bottom_uvs.append(uv2)
				bottom_indices.append(start_idx)
				bottom_indices.append(start_idx + 1)
				bottom_indices.append(start_idx + 2)
			else:
				# SIDES surface
				var start_idx = sides_verts.size()
				sides_verts.append(v0)
				sides_verts.append(v1)
				sides_verts.append(v2)
				sides_normals.append(n0)
				sides_normals.append(n1)
				sides_normals.append(n2)
				sides_uvs.append(uv0)
				sides_uvs.append(uv1)
				sides_uvs.append(uv2)
				sides_indices.append(start_idx)
				sides_indices.append(start_idx + 1)
				sides_indices.append(start_idx + 2)
	
	# Build the reclassified mesh with 3 surfaces: TOP, SIDES, BOTTOM
	var new_mesh = ArrayMesh.new()
	
	# Surface 0: TOP
	if top_verts.size() > 0:
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = top_verts
		surface_array[Mesh.ARRAY_NORMAL] = top_normals
		surface_array[Mesh.ARRAY_TEX_UV] = top_uvs
		surface_array[Mesh.ARRAY_INDEX] = top_indices
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
	
	# Surface 1: SIDES
	if sides_verts.size() > 0:
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = sides_verts
		surface_array[Mesh.ARRAY_NORMAL] = sides_normals
		surface_array[Mesh.ARRAY_TEX_UV] = sides_uvs
		surface_array[Mesh.ARRAY_INDEX] = sides_indices
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
	
	# Surface 2: BOTTOM
	if bottom_verts.size() > 0:
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = bottom_verts
		surface_array[Mesh.ARRAY_NORMAL] = bottom_normals
		surface_array[Mesh.ARRAY_TEX_UV] = bottom_uvs
		surface_array[Mesh.ARRAY_INDEX] = bottom_indices
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
	
	return new_mesh



func _on_preview_input(event: InputEvent) -> void:
	"""Handle mouse input on the preview for manual rotation"""
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				preview_rect.set_default_cursor_shape(Control.CURSOR_DRAG)
			else:
				preview_rect.set_default_cursor_shape(Control.CURSOR_ARROW)
	
	elif event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if preview_mesh:
				preview_mesh.rotate_y(event.relative.x * 0.01)
				preview_mesh.rotate_x(event.relative.y * 0.01)
		
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			if preview_mesh:
				preview_mesh.rotate_z(event.relative.x * 0.01)
				preview_mesh.rotate_x(event.relative.y * 0.01)


func _update_preview_material() -> void:
	if not preview_mesh:
		return
	
	var surface_count = preview_mesh.mesh.get_surface_count()
	
	if surface_count >= 3:
		# Surface 0 = TOP, Surface 1 = SIDES, Surface 2 = BOTTOM
		var top_material = _create_material_for_surface("top")
		preview_mesh.set_surface_override_material(0, top_material)
		
		var side_material = _create_material_for_surface("side")
		preview_mesh.set_surface_override_material(1, side_material)
		
		var bottom_material = _create_material_for_surface("bottom")
		preview_mesh.set_surface_override_material(2, bottom_material)


func _create_material_for_surface(surface_type: String) -> StandardMaterial3D:
	"""Create a material for a specific surface (top, side, or bottom)"""
	var material := StandardMaterial3D.new()
	
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.uv1_triplanar_sharpness = 4.0
	
	var texture_key = surface_type + "_texture"
	var normal_key = surface_type + "_normal"
	
	if material_data.get(texture_key, "") != "":
		var texture := load(material_data[texture_key])
		if texture:
			material.albedo_texture = texture
	
	if material_data.get(normal_key, "") != "":
		var normal := load(material_data[normal_key])
		if normal:
			material.normal_enabled = true
			material.normal_texture = normal
	
	return material




func _on_texture_button_pressed(texture_type: String) -> void:
	if texture_type.ends_with("_normal") and material_data.get(texture_type, "") != "":
		material_data[texture_type] = ""
		_update_button_text(texture_type, "Choose")
		_update_preview_material()
		return
	
	current_texture_type = texture_type
	file_dialog.popup_centered(Vector2i(800, 600))


func _update_button_text(texture_type: String, text: String) -> void:
	match texture_type:
		"top_normal":
			top_normal_btn.text = text
		"side_normal":
			side_normal_btn.text = text
		"bottom_normal":
			bottom_normal_btn.text = text


func _on_file_selected(path: String) -> void:
	material_data[current_texture_type] = path
	
	var filename := path.get_file()
	match current_texture_type:
		"top_texture":
			top_texture_btn.text = filename
		"top_normal":
			top_normal_btn.text = filename
		"side_texture":
			side_texture_btn.text = filename
		"side_normal":
			side_normal_btn.text = filename
		"bottom_texture":
			bottom_texture_btn.text = filename
		"bottom_normal":
			bottom_normal_btn.text = filename
	
	_update_preview_material()


func _on_save_pressed() -> void:
	material_data.name = material_name_input.text
	
	if material_data.name == "":
		push_warning("Material needs a name!")
		return
	
	# FIXED: Check if we're editing or creating new
	if is_editing:
		material_edited.emit(editing_index, material_data.duplicate())
		print("Material edited at index ", editing_index)
	else:
		material_created.emit(material_data.duplicate())
		print("New material created")
	
	hide()


func _on_cancel_pressed() -> void:
	hide()


func _reset_form() -> void:
	# FIXED: Clear edit mode
	is_editing = false
	editing_index = -1
	
	material_name_input.text = ""
	material_data = {
		"name": "",
		"top_texture": "",
		"top_normal": "",
		"side_texture": "",
		"side_normal": "",
		"bottom_texture": "",
		"bottom_normal": ""
	}
	
	top_texture_btn.text = "Choose"
	top_normal_btn.text = "Choose"
	side_texture_btn.text = "Choose"
	side_normal_btn.text = "Choose"
	bottom_texture_btn.text = "Choose"
	bottom_normal_btn.text = "Choose"
	
	_update_preview_material()


func show_popup() -> void:
	popup_centered()


# FIXED: Pass index when editing
func edit_material(material_dict: Dictionary, index: int) -> void:
	is_editing = true
	editing_index = index
	
	material_data = material_dict.duplicate()
	material_name_input.text = material_dict.get("name", "")
	
	if material_dict.get("top_texture", "") != "":
		top_texture_btn.text = material_dict.top_texture.get_file()
	if material_dict.get("top_normal", "") != "":
		top_normal_btn.text = material_dict.top_normal.get_file()
	if material_dict.get("side_texture", "") != "":
		side_texture_btn.text = material_dict.side_texture.get_file()
	if material_dict.get("side_normal", "") != "":
		side_normal_btn.text = material_dict.side_normal.get_file()
	if material_dict.get("bottom_texture", "") != "":
		bottom_texture_btn.text = material_dict.bottom_texture.get_file()
	if material_dict.get("bottom_normal", "") != "":
		bottom_normal_btn.text = material_dict.bottom_normal.get_file()
	
	_update_preview_material()
	popup_centered()


func _on_about_to_popup() -> void:
	popup_opened.emit()


func _on_popup_hide() -> void:
	popup_closed.emit()
	_reset_form()
