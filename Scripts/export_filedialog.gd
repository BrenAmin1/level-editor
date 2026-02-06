extends FileDialog

# Emitted when user confirms export with the selected format and path
signal export_confirmed(format_index: int, filepath: String)

# Export format constants
enum ExportFormat {
	SINGLE_MESH = 0,
	CHUNKED = 1,
	GLTF = 2
}

func _ready():
	# Connect to own file_selected signal
	file_selected.connect(_on_file_selected)


func _on_file_selected(path: String):
	"""Handle file selection and emit with format info"""
	# Get the selected format from the dialog option
	# The selected option is stored separately from the option values
	var format_index = get_selected_options()[0] if get_selected_options().size() > 0 else 0
	
	# Emit to level_editor with both pieces of info
	export_confirmed.emit(format_index, path)
	
	# Debug output
	var format_names = ["Single Mesh (.tres)", "Chunked Meshes", "glTF 2.0"]
	print("Export dialog: User selected ", format_names[format_index], " → ", path)
