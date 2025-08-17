# Scripts/Systems/FloatingOrigin.gd
extends Node
# Note: No class_name declaration - this is a singleton/autoload

# Singleton pattern
static var instance

# Origin management
var origin_offset: Vector2 = Vector2.ZERO  # Total offset applied to world
var threshold_distance: float = 10000.0    # Reorigin when camera >10k pixels from origin
var last_reorigin_time: float = 0.0
var min_reorigin_interval: float = 0.1     # Don't reorigin more than 10Hz

# References
var camera: Camera2D = null

# Statistics
var reorigin_count: int = 0
var total_offset_applied: Vector2 = Vector2.ZERO

# Debug
@export var debug_enabled: bool = true
@export var show_debug_overlay: bool = false

signal origin_shifted(offset: Vector2)

func _enter_tree():
	# Singleton setup
	if instance == null:
		instance = self
		# Make persistent
		set_process_mode(Node.PROCESS_MODE_ALWAYS)
	else:
		queue_free()

func _ready():
	# Find camera
	call_deferred("setup_camera")
	
	if debug_enabled:
		print("[FloatingOrigin] Initialized with threshold: %.0f pixels" % threshold_distance)

func setup_camera():
	camera = get_tree().get_first_node_in_group("game_camera")
	if not camera:
		camera = get_node_or_null("/root/WorldRoot/GameCamera")
	
	if not camera:
		push_error("[FloatingOrigin] Could not find game camera!")
	else:
		print("[FloatingOrigin] Camera found and linked")

func _physics_process(_delta):
	if not camera:
		return
	
	# Check if we need to reorigin
	var camera_distance = camera.global_position.length()
	
	if camera_distance > threshold_distance:
		var current_time = Time.get_ticks_msec() / 1000.0
		if current_time - last_reorigin_time > min_reorigin_interval:
			perform_reorigin()
			last_reorigin_time = current_time

func perform_reorigin():
	"""Shift the entire world to bring camera back near origin"""
	if not camera:
		return
	
	# Calculate shift needed
	var shift_offset = -camera.global_position
	
	# Round to nearest pixel to avoid sub-pixel issues
	shift_offset = shift_offset.round()
	
	if shift_offset.length() < 1.0:
		return  # Too small to bother
	
	reorigin_count += 1
	origin_offset += shift_offset
	total_offset_applied += shift_offset
	
	if debug_enabled:
		var shift_km = shift_offset.length() * WorldSettings.meters_per_pixel / 1000.0
		print("[FloatingOrigin] Reorigin #%d: Shifting world by %.1f km" % [reorigin_count, shift_km])
		print("  Camera was at: %s" % camera.global_position)
		print("  Total offset now: %.0f, %.0f pixels (%.1f, %.1f km)" % [
			origin_offset.x, origin_offset.y,
			origin_offset.x * WorldSettings.meters_per_pixel / 1000.0,
			origin_offset.y * WorldSettings.meters_per_pixel / 1000.0
		])
	
	# Apply shift to all relevant nodes
	apply_shift_to_world(shift_offset)
	
	# Emit signal for any custom handlers
	origin_shifted.emit(shift_offset)

func apply_shift_to_world(offset: Vector2):
	"""Apply position shift to all game objects"""
	
	# Shift camera FIRST to prevent view jumping
	camera.global_position += offset
	
	# Shift all ships
	for ship in get_tree().get_nodes_in_group("ships"):
		if is_instance_valid(ship):
			ship.global_position += offset
	
	# Shift all torpedoes
	for torpedo in get_tree().get_nodes_in_group("torpedoes"):
		if is_instance_valid(torpedo):
			torpedo.global_position += offset
			# Also shift the intercept point if stored
			if "intercept_point" in torpedo:
				torpedo.intercept_point += offset
	
	# Shift all PDC bullets
	for bullet in get_tree().get_nodes_in_group("bullets"):
		if is_instance_valid(bullet):
			bullet.global_position += offset
	
	# Shift any trajectory lines
	for node in get_tree().get_nodes_in_group("trajectory_lines"):
		if is_instance_valid(node) and node is Line2D:
			var points = node.points
			for i in range(points.size()):
				points[i] += offset
			node.points = points
	
	# Shift selection indicator if it exists
	var selection_indicator = get_tree().get_first_node_in_group("selection_indicator")
	if selection_indicator and is_instance_valid(selection_indicator):
		selection_indicator.global_position += offset

func get_true_world_position(visual_position: Vector2) -> Vector2:
	"""Convert a visual position to true world position"""
	return visual_position - origin_offset

func get_visual_position(true_position: Vector2) -> Vector2:
	"""Convert a true world position to visual position"""
	return true_position + origin_offset

func get_true_distance(pos1: Vector2, pos2: Vector2) -> float:
	"""Calculate true distance between two visual positions"""
	# Visual positions are already in the same space, so distance is correct
	return pos1.distance_to(pos2)

func reset():
	"""Reset the floating origin system"""
	origin_offset = Vector2.ZERO
	total_offset_applied = Vector2.ZERO
	reorigin_count = 0
	last_reorigin_time = 0.0
	
	if debug_enabled:
		print("[FloatingOrigin] System reset")

# Debug overlay for development
func _draw():
	if not show_debug_overlay:
		return
	
	# This would need to be in a CanvasLayer node to draw properly
	# Just providing the structure for reference
	pass

func get_debug_info() -> String:
	var camera_dist = camera.global_position.length() if camera else 0.0
	return "Origin: (%.0f, %.0f) | Camera: %.0f px | Reorigins: %d" % [
		origin_offset.x, origin_offset.y,
		camera_dist,
		reorigin_count
	]

# Static helper functions for easy access
static func shift_occurred() -> bool:
	return instance != null and instance.origin_offset != Vector2.ZERO

static func get_offset() -> Vector2:
	if instance:
		return instance.origin_offset
	return Vector2.ZERO

static func true_to_visual(true_pos: Vector2) -> Vector2:
	if instance:
		return instance.get_visual_position(true_pos)
	return true_pos

static func visual_to_true(visual_pos: Vector2) -> Vector2:
	if instance:
		return instance.get_true_world_position(visual_pos)
	return visual_pos
