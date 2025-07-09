# Scripts/Systems/TorpedoLauncher.gd - IMMEDIATE STATE REFACTOR
extends Node2D
class_name TorpedoLauncher

# Launcher configuration
@export var launcher_id: String = ""
@export var tubes_per_side: int = 2
@export var reload_time: float = 10.0
@export var launch_sequence_delay: float = 0.2

# Tube spacing configuration
@export var tube_spacing: float = 30.0
@export var lateral_offset: float = 60.0

# Launch state
var port_tubes_ready: int
var starboard_tubes_ready: int
var reload_timers: Dictionary = {}  # "port_0", "starboard_1" -> float

# References
var parent_ship: Node2D
var torpedo_scene = preload("res://Scenes/Torpedo.tscn")

# Launch sequence
var launch_queue: Array = []
var launch_timer: float = 0.0

func _ready():
	parent_ship = get_parent()
	
	# Generate ID if not provided
	if launcher_id == "":
		launcher_id = "launcher_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# Initialize tubes
	port_tubes_ready = tubes_per_side
	starboard_tubes_ready = tubes_per_side
	
	# Initialize reload timers
	for i in range(tubes_per_side):
		reload_timers["port_%d" % i] = 0.0
		reload_timers["starboard_%d" % i] = 0.0
	
	print("Torpedo launcher initialized: %s with %d tubes per side" % [launcher_id, tubes_per_side])

func _physics_process(delta):
	# Process reload timers
	for tube_id in reload_timers:
		if reload_timers[tube_id] > 0:
			reload_timers[tube_id] -= delta
			if reload_timers[tube_id] <= 0:
				reload_timers[tube_id] = 0.0
				on_tube_reloaded(tube_id)
	
	# Process launch queue
	if launch_queue.size() > 0:
		launch_timer -= delta
		if launch_timer <= 0:
			var launch_data = launch_queue.pop_front()
			_launch_single_torpedo(launch_data.target, launch_data.side, launch_data.tube_index)
			launch_timer = launch_sequence_delay

func fire_torpedo(target: Node2D):
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
	
	# Queue torpedoes for launch
	launch_queue.clear()
	
	# Fire from the side facing the target first
	if is_target_starboard:
		queue_side_launch(target, 1)  # Starboard
		queue_side_launch(target, -1)  # Port
	else:
		queue_side_launch(target, -1)  # Port
		queue_side_launch(target, 1)  # Starboard
	
	print("Firing %d torpedoes at target" % launch_queue.size())

func queue_side_launch(target: Node2D, side: int):
	var ready_count = starboard_tubes_ready if side == 1 else port_tubes_ready
	
	for i in range(tubes_per_side):
		var tube_id = ("starboard_%d" if side == 1 else "port_%d") % i
		if reload_timers[tube_id] == 0.0 and ready_count > 0:
			launch_queue.append({
				"target": target,
				"side": side,
				"tube_index": i
			})
			
			# Mark tube as firing
			reload_timers[tube_id] = reload_time
			if side == 1:
				starboard_tubes_ready -= 1
			else:
				port_tubes_ready -= 1
			ready_count -= 1

func _launch_single_torpedo(target: Node2D, side: int, tube_index: int):
	if not torpedo_scene or not is_valid_target(target):
		return
	
	var torpedo = torpedo_scene.instantiate()
	get_tree().root.add_child(torpedo)
	
	# Calculate launch position
	var ship_forward = Vector2.UP.rotated(parent_ship.rotation)
	var ship_right = Vector2.UP.rotated(parent_ship.rotation + PI/2)
	
	var side_offset = ship_right * lateral_offset * side
	var tube_offset = ship_forward * (tube_index - (tubes_per_side - 1) * 0.5) * tube_spacing
	
	torpedo.global_position = parent_ship.global_position + side_offset + tube_offset
	
	# Configure torpedo
	torpedo.set_target(target)
	torpedo.set_launcher(parent_ship)
	torpedo.set_launch_side(side)
	
	# Set faction from parent ship
	if "faction" in parent_ship:
		torpedo.faction = parent_ship.faction
	
	print("Torpedo launched from %s tube %d" % ["starboard" if side == 1 else "port", tube_index])

func on_tube_reloaded(tube_id: String):
	if tube_id.begins_with("port"):
		port_tubes_ready += 1
	else:
		starboard_tubes_ready += 1
	
	print("Tube %s reloaded" % tube_id)

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

func get_reload_status() -> Dictionary:
	var status = {
		"port_ready": port_tubes_ready,
		"starboard_ready": starboard_tubes_ready,
		"reloading": {}
	}
	
	for tube_id in reload_timers:
		if reload_timers[tube_id] > 0:
			status.reloading[tube_id] = reload_timers[tube_id]
	
	return status
