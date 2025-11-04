class_name TypeSystem extends Resource

##The name of the type. Should be all caps
@export var type_name: String = "":
	set(value):
		# Auto-convert to uppercase instead of validation
		_type_name = value.to_upper()
	get:
		return _type_name

@export var type_texture : Texture2D = PlaceholderTexture2D.new()

# Private variable to store the actual type name
var _type_name: String = ""

# Called after the node and its children have entered the tree
func _ready():
	# Force uppercase
	type_name = type_name.to_upper()

# Helper function to validate and get the proper type name
func get_validated_type_name() -> String:
	# Ensure type_name is uppercase at point of use
	if type_name != type_name.to_upper():
		type_name = type_name.to_upper()
		push_warning("Type name was automatically converted to uppercase: " + type_name)
	return type_name
