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

signal material_created(material_dict: Dictionary)

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
	
	# Setup 3D preview
	_setup_3d_preview()
	
	# Connect to popup signals
	popup_hide.connect(_on_popup_hide)

func _setup_file_dialog() -> void:
	file_dialog = FileDialog.new()
	add_child(file_dialog)
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg ; Image Files"])
	file_dialog.use_native_dialog = true  # Use native OS file dialog
	file_dialog.file_selected.connect(_on_file_selected)
	
	# Prevent popup from closing when file dialog opens
	set_exclusive(false)

func _setup_3d_preview() -> void:
	# Create SubViewport for 3D rendering
	preview_viewport = SubViewport.new()
	preview_viewport.size = Vector2i(160, 160)
	preview_viewport.transparent_bg = true
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(preview_viewport)
	
	# Create camera
	preview_camera = Camera3D.new()
	var cam_pos = Vector3(1.5, 1.5, 1.5)
	var look_target = Vector3.ZERO
	# Use look_at_from_position which doesn't require being in tree
	preview_camera.look_at_from_position(cam_pos, look_target, Vector3.UP)
	preview_viewport.add_child(preview_camera)
	
	# Create light
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	preview_viewport.add_child(light)
	
	# Load the cube mesh
	var mesh_resource := load("res://cubes/cube_bulge.obj") # Adjust path as needed
	if mesh_resource:
		preview_mesh = MeshInstance3D.new()
		preview_mesh.mesh = mesh_resource
		preview_viewport.add_child(preview_mesh)
		
		# Create initial material
		_update_preview_material()
	else:
		push_warning("Could not load cube_bulge.obj - check the path in material_maker_popup.gd")
	
	# Set viewport texture to preview rect
	preview_rect.texture = preview_viewport.get_texture()
	
	# Start rotation timer
	var timer := Timer.new()
	add_child(timer)
	timer.timeout.connect(_rotate_preview)
	timer.wait_time = 0.016 # ~60 FPS
	timer.start()

func _rotate_preview() -> void:
	if preview_mesh:
		preview_mesh.rotate_y(0.01)

func _update_preview_material() -> void:
	if not preview_mesh:
		return
	
	var material := StandardMaterial3D.new()
	
	# Load textures if they exist
	if material_data.top_texture != "":
		var texture := load(material_data.top_texture)
		if texture:
			material.albedo_texture = texture
	
	if material_data.top_normal != "":
		var normal := load(material_data.top_normal)
		if normal:
			material.normal_enabled = true
			material.normal_texture = normal
	
	preview_mesh.material_override = material

func _on_texture_button_pressed(texture_type: String) -> void:
	current_texture_type = texture_type
	file_dialog.popup_centered(Vector2i(800, 600))

func _on_file_selected(path: String) -> void:
	material_data[current_texture_type] = path
	
	# Update button text to show filename
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
	
	# Validate that at least a name is provided
	if material_data.name == "":
		push_warning("Material needs a name!")
		return
	
	# Emit signal with material data
	material_created.emit(material_data.duplicate())
	hide()

func _on_cancel_pressed() -> void:
	hide()

func _on_popup_hide() -> void:
	# Clear data when popup closes
	_reset_form()

func _reset_form() -> void:
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
	
	# Reset button texts
	top_texture_btn.text = "Choose"
	top_normal_btn.text = "Choose"
	side_texture_btn.text = "Choose"
	side_normal_btn.text = "Choose"
	bottom_texture_btn.text = "Choose"
	bottom_normal_btn.text = "Choose"
	
	_update_preview_material()

# Call this to show the popup
func show_popup() -> void:
	popup_centered()

# Call this to edit an existing material
func edit_material(material_dict: Dictionary) -> void:
	# Populate the form with existing data
	material_data = material_dict.duplicate()
	material_name_input.text = material_dict.get("name", "")
	
	# Set texture paths and update button labels
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
	
	# Update preview
	_update_preview_material()
	
	# Show the popup
	popup_centered()
