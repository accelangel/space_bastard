# Scripts/Entities/Weapons/TorpedoLauncher.gd - SIMPLIFIED VERSION
extends Node2D
class_name TorpedoLauncher

# Basic launcher configuration
@export var launcher_id: String = ""
@export var reload_time: float = 10.0

# Fixed launcher parameters
const TUBES_PER_SIDE: int = 2  # 2 port, 2 starboard
const TUBE_SPACING: float = 30.0  # pixels between tubes
const LATERAL_OFFSET: float = 60.0  # pixels from ship center to tubes

# Launch state
var port_tubes_ready: int = TUBES_PER_SIDE
var starboard_tubes_ready: int = TUBES_PER_SIDE
var reload_timers: Dictionary = {}  # "port_0", "starboard_1" -> float

# References
var parent_ship: Node2D
var torpedo_scene = preload("res://Scenes/Torpedo.tscn")

func _ready():
	parent_ship = get_parent()
	
	# Generate ID if not provided
	if launcher_id == "":
		launcher_id = "launcher_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# Initialize reload timers
	for i in range(TUBES_PER_SIDE):
		reload_timers["port_%d" % i] = 0.0
		reload_timers["starboard_%d" % i] = 0.0
	
	# Add to group for easy finding
	add_to_group("torpedo_launchers")
	
	print("Torpedo launcher initialized")

func _physics_process(delta):
	# Process reload timers
	for tube_id in reload_timers:
		if reload_timers[tube_id] > 0:
			reload_timers[tube_id] -= delta
			if reload_timers[tube_id] <= 0:
				reload_timers[tube_id] = 0.0
				on_tube_reloaded(tube_id)

func fire_torpedo(target: Node2D):
	"""Main public interface - fire torpedo at target"""
	if not is_valid_target(target):
		print("Invalid target provided to torpedo launcher")
		return
	
	var total_ready = port_tubes_ready + starboard_tubes_ready
	if total_ready == 0:
		print("No torpedo tubes ready")
		return
	
	# Determine which side to fire from based on target position
	var to_target = target.global_position - global_position
	var ship_right = Vector2.UP.rotated(parent_ship.rotation + PI/2)
	var is_target_starboard = to_target.dot(ship_right) > 0
	
	# Fire from the side facing the target first
	if is_target_starboard and starboard_tubes_ready > 0:
		fire_from_side(target, 1, 0)  # Starboard, tube 0
	elif not is_target_starboard and port_tubes_ready > 0:
		fire_from_side(target, -1, 0)  # Port, tube 0
	elif starboard_tubes_ready > 0:
		fire_from_side(target, 1, 0)  # Fallback to starboard
	elif port_tubes_ready > 0:
		fire_from_side(target, -1, 0)  # Fallback to port
	else:
		print("No tubes available")

func fire_from_side(target: Node2D, side: int, tube_index: int):
	"""Fire torpedo from specific side and tube"""
	var tube_id = ("starboard_%d" if side == 1 else "port_%d") % tube_index
	
	# Check if tube is ready
	if reload_timers[tube_id] > 0.0:
		print("Tube %s not ready" % tube_id)
		return
	
	# Create torpedo
	var torpedo = torpedo_scene.instantiate()
	
	# Configure torpedo BEFORE adding to scene
	torpedo.set_target(target)
	torpedo.set_launcher(parent_ship)
	
	# Set faction from parent ship
	if "faction" in parent_ship:
		torpedo.faction = parent_ship.faction
	
	# Calculate launch position
	var ship_forward = Vector2.UP.rotated(parent_ship.rotation)
	var ship_right = Vector2.UP.rotated(parent_ship.rotation + PI/2)
	
	var side_offset = ship_right * LATERAL_OFFSET * side
	var tube_offset = ship_forward * (tube_index - (TUBES_PER_SIDE - 1) * 0.5) * TUBE_SPACING
	
	# Set position and rotation BEFORE adding to scene
	torpedo.global_position = parent_ship.global_position + side_offset + tube_offset
	torpedo.rotation = parent_ship.rotation
	
	# Add to scene AFTER configuration
	get_tree().root.add_child(torpedo)
	
	# Mark tube as firing and start reload
	reload_timers[tube_id] = reload_time
	if side == 1:
		starboard_tubes_ready -= 1
	else:
		port_tubes_ready -= 1
	
	print("Torpedo fired from %s at %s" % [tube_id, target.name])

func on_tube_reloaded(tube_id: String):
	if tube_id.begins_with("port"):
		port_tubes_ready += 1
	else:
		starboard_tubes_ready += 1
	
	#print("Tube %s reloaded" % tube_id)

func is_valid_target(target: Node2D) -> bool:
	if not target:
		return false
	if not is_instance_valid(target):
		return false
	if not target.is_inside_tree():
		return false
	if target.has_method("is_alive") and not target.is_alive:
		return false
	if target.get("marked_for_death") and target.marked_for_death:
		return false
	return true

func get_ready_tube_count() -> int:
	return port_tubes_ready + starboard_tubes_ready

func reset_all_tubes():
	"""Reset all tubes to ready state"""
	port_tubes_ready = TUBES_PER_SIDE
	starboard_tubes_ready = TUBES_PER_SIDE
	for tube_id in reload_timers:
		reload_timers[tube_id] = 0.0
