extends FileDialog

# Emitted when user confirms save
signal save_confirmed(filepath: String)

func _ready():
	# Connect to own file_selected signal
	file_selected.connect(_on_file_selected)


func _on_file_selected(path: String):
	"""Handle file selection and ensure .json extension"""
	# Ensure .json extension
	if not path.ends_with(".json"):
		path += ".json"
	
	# Emit to level_editor
	save_confirmed.emit(path)
	
	print("Save dialog: User selected → ", path)
