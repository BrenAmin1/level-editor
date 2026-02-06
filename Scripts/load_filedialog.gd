extends FileDialog

# Emitted when user confirms load
signal load_confirmed(filepath: String)

func _ready():
	# Connect to own file_selected signal
	file_selected.connect(_on_file_selected)


func _on_file_selected(path: String):
	"""Handle file selection"""
	# Check if file exists
	if not FileAccess.file_exists(path):
		push_error("File does not exist: " + path)
		return
	
	# Emit to level_editor
	load_confirmed.emit(path)
	
	print("Load dialog: User selected → ", path)
