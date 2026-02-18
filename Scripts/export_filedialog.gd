extends FileDialog

signal export_confirmed(is_chunked: bool, filepath: String)

func _ready():
	# Save as Type dropdown — controls file format only
	filters = PackedStringArray([
		"*.tres ; Mesh Resource (.tres)",
		"*.gltf ; glTF 2.0 (.gltf)",
		"*.glb ; glTF Binary (.glb)"
	])

	# Format dropdown — controls single vs chunked only
	add_option("Format", ["Single", "Chunked"], 0)

	file_selected.connect(_on_file_selected)


func _on_file_selected(path: String):
	# Read format option: 0 = Single, 1 = Chunked
	var is_chunked = get_selected_options().get(0, 0) == 1

	# Ensure the path has a valid extension
	var ext = path.get_extension().to_lower()
	if ext != "tres" and ext != "gltf" and ext != "glb":
		path += ".tres"

	export_confirmed.emit(is_chunked, path)

	var export_mode = "Chunked" if is_chunked else "Single"
	print("Export dialog: ", export_mode, " (.", path.get_extension(), ") → ", path)
