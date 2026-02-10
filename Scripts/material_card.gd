extends Control

signal material_card_selected(index: int)

var material_data: Dictionary = {}
var card_index: int = -1
var is_selected: bool = false

@onready var preview_texture: TextureRect = %Preview
@onready var name_label: Label = %Label
@onready var button: Button = %Button

func _ready() -> void:
	if button:
		button.pressed.connect(_on_button_pressed)


func setup(mat_data: Dictionary, index: int) -> void:
	material_data = mat_data
	card_index = index
	
	# Set the material name
	if name_label:
		name_label.text = mat_data.get("name", "Unnamed")
	
	# Load and set the preview texture if available
	_update_preview()


func _update_preview() -> void:
	if not preview_texture:
		return
	
	# Try to load the top texture as preview
	var texture_path = material_data.get("top_texture", "")
	if texture_path != "" and FileAccess.file_exists(texture_path):
		var texture = load(texture_path)
		if texture:
			preview_texture.texture = texture
			return
	
	# If no top texture, try side texture
	texture_path = material_data.get("side_texture", "")
	if texture_path != "" and FileAccess.file_exists(texture_path):
		var texture = load(texture_path)
		if texture:
			preview_texture.texture = texture
			return
	
	# If no textures at all, create a colored placeholder based on material name
	var material_name = material_data.get("name", "").to_lower()
	if material_name.contains("grass"):
		_create_colored_placeholder(Color(0.3, 0.6, 0.2))  # Green
	elif material_name.contains("dirt") or material_name.contains("earth"):
		_create_colored_placeholder(Color(0.5, 0.35, 0.2))  # Brown
	elif material_name.contains("stone") or material_name.contains("rock"):
		_create_colored_placeholder(Color(0.5, 0.5, 0.5))  # Gray
	elif material_name.contains("water"):
		_create_colored_placeholder(Color(0.2, 0.4, 0.7))  # Blue
	elif material_name.contains("sand"):
		_create_colored_placeholder(Color(0.8, 0.7, 0.5))  # Tan
	# Otherwise use the existing placeholder texture from the scene


func _create_colored_placeholder(color: Color) -> void:
	# Create a simple colored texture as placeholder
	var img = Image.create(64, 64, false, Image.FORMAT_RGB8)
	img.fill(color)
	var texture = ImageTexture.create_from_image(img)
	preview_texture.texture = texture


func _on_button_pressed() -> void:
	material_card_selected.emit(card_index)


func set_selected(selected: bool) -> void:
	is_selected = selected
	if button:
		button.button_pressed = selected


func update_index(new_index: int) -> void:
	card_index = new_index


func get_material_data() -> Dictionary:
	return material_data
