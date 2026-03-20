extends FileDialog

# Emitted when user confirms save
signal save_confirmed(filepath: String)

func _ready():
	file_selected.connect(_on_file_selected)


func _on_file_selected(path: String):
	"""Handle file selection — extension is enforced by level_editor._on_save_confirmed."""
	save_confirmed.emit(path)
	print("Save dialog: User selected → ", path)
