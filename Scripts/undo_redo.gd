class_name UndoRedoManager extends RefCounted

# ============================================================================
# UNDO/REDO MANAGER
# Stores tile snapshots before/after each action so they can be reversed.
#
# A "snapshot" is an Array of TileSaveState dicts:
#   { pos: Vector3i, type: int, rotation: float, material: int }
# type == -1 means "no tile here" (used in before-snapshots for new placements
# and in after-snapshots for deletions).
#
# Usage:
#   undo_redo.begin_action()                 <- call before modifying tiles
#   ... place / remove / paint tiles ...
#   undo_redo.end_action()                   <- call after; saves to history
#
# For batch operations (SelectionManager), capture before/after externally:
#   var before = undo_redo.snapshot_positions(positions)
#   ... do the operation ...
#   undo_redo.commit_action(before, undo_redo.snapshot_positions(positions))
# ============================================================================

const MAX_HISTORY: int = 100

var tilemap: TileMap3D
var material_palette_ref = null

var _history: Array = []    # Array of { before: Array, after: Array }
var _redo_stack: Array = [] # Array of { before: Array, after: Array }

# For incremental single-tile recording (used during live painting/placing)
var _pending_before: Dictionary = {}  # pos -> snapshot, captured before first touch
var _action_open: bool = false

# ============================================================================
# SETUP
# ============================================================================

func setup(tm: TileMap3D, palette = null) -> void:
	tilemap = tm
	material_palette_ref = palette


func set_material_palette_reference(palette) -> void:
	material_palette_ref = palette


# ============================================================================
# INCREMENTAL ACTION API  (for single-tile brush strokes)
# ============================================================================

func begin_action() -> void:
	"""Open a new action. Call once at mouse-press before tile modifications."""
	if _action_open:
		return
	_action_open = true
	_pending_before.clear()


func record_tile_before(pos: Vector3i) -> void:
	"""
	Snapshot the state at pos BEFORE it is modified.
	Safe to call multiple times for the same pos in one action - only first is kept.
	"""
	if not _action_open:
		return
	if pos in _pending_before:
		return  # Already captured for this action
	_pending_before[pos] = _capture_tile(pos)


func end_action() -> void:
	"""
	Close the current action. Captures after-state for every position that was
	recorded with record_tile_before(), then pushes to history.
	"""
	if not _action_open:
		return
	_action_open = false

	if _pending_before.is_empty():
		return

	var before_snaps: Array = []
	var after_snaps: Array = []

	for pos in _pending_before:
		var before = _pending_before[pos]
		var after = _capture_tile(pos)
		# Skip if nothing actually changed
		if _snapshots_equal(before, after):
			continue
		before_snaps.append(before)
		after_snaps.append(after)

	_pending_before.clear()

	if before_snaps.is_empty():
		return

	_push_action(before_snaps, after_snaps)


# ============================================================================
# BATCH ACTION API  (for SelectionManager mass operations)
# ============================================================================

func snapshot_positions(positions: Array) -> Array:
	"""
	Capture the current state of a list of Vector3i positions.
	Call before AND after a batch operation, then pass both to commit_action().
	"""
	var snaps: Array = []
	for pos in positions:
		snaps.append(_capture_tile(pos))
	return snaps


func commit_action(before_snaps: Array, after_snaps: Array) -> void:
	"""Push a completed batch action to history."""
	if before_snaps.is_empty():
		return
	# Filter out positions where nothing changed
	var filtered_before: Array = []
	var filtered_after: Array = []
	for i in range(mini(before_snaps.size(), after_snaps.size())):
		if not _snapshots_equal(before_snaps[i], after_snaps[i]):
			filtered_before.append(before_snaps[i])
			filtered_after.append(after_snaps[i])
	if filtered_before.is_empty():
		return
	_push_action(filtered_before, filtered_after)


# ============================================================================
# UNDO / REDO
# ============================================================================

func undo() -> void:
	if _history.is_empty():
		print("Nothing to undo")
		return
	var action = _history.pop_back()
	_apply_snapshots(action["before"])
	_redo_stack.push_back(action)
	print("Undo — ", action["before"].size(), " tile(s) restored")


func redo() -> void:
	if _redo_stack.is_empty():
		print("Nothing to redo")
		return
	var action = _redo_stack.pop_back()
	_apply_snapshots(action["after"])
	_history.push_back(action)
	print("Redo — ", action["after"].size(), " tile(s) re-applied")


func can_undo() -> bool:
	return not _history.is_empty()


func can_redo() -> bool:
	return not _redo_stack.is_empty()


func clear() -> void:
	_history.clear()
	_redo_stack.clear()
	_pending_before.clear()
	_action_open = false


# ============================================================================
# PRIVATE HELPERS
# ============================================================================

func _push_action(before: Array, after: Array) -> void:
	_redo_stack.clear()  # New action always kills redo history
	_history.push_back({ "before": before, "after": after })
	if _history.size() > MAX_HISTORY:
		_history.pop_front()


func _capture_tile(pos: Vector3i) -> Dictionary:
	"""Returns a full snapshot of the tile at pos, or a 'no tile' marker."""
	if not tilemap.has_tile(pos):
		return { "pos": pos, "type": -1, "rotation": 0.0, "material": -1 }
	return {
		"pos": pos,
		"type": tilemap.get_tile_type(pos),
		"rotation": tilemap.get_tile_rotation(pos),
		"material": tilemap.get_tile_material_index(pos)
	}


func _snapshots_equal(a: Dictionary, b: Dictionary) -> bool:
	return (a["type"] == b["type"]
		and a["rotation"] == b["rotation"]
		and a["material"] == b["material"])


func _apply_snapshots(snaps: Array) -> void:
	"""Restore a list of tile snapshots, using batch mode for efficiency."""
	tilemap.set_batch_mode(true)
	for snap in snaps:
		var pos: Vector3i = snap["pos"]
		if snap["type"] == -1:
			# Should be empty
			if tilemap.has_tile(pos):
				tilemap.remove_tile(pos)
		else:
			# Should exist with these properties
			tilemap.place_tile(pos, snap["type"])
			tilemap.set_tile_rotation(pos, snap["rotation"])
			if snap["material"] >= 0 and material_palette_ref:
				tilemap.apply_material_to_tile(pos, snap["material"], material_palette_ref)
	tilemap.set_batch_mode(false)
