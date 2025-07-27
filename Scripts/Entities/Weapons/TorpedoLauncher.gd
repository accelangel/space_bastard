# Scripts/Entities/Weapons/TorpedoLauncher.gd - REFACTORED VERSION
extends Node2D
class_name TorpedoLauncher

# Launcher configuration
@export var launcher_id: String = ""

# Trajectory selection (only one can be true)
@export var use_straight_trajectory: bool = true
@export var use_multi_angle_trajectory: bool = false
@export var use_simultaneous_impact: bool = false
@export var auto_volley: bool = false  # MUST BE FALSE - manual fire only

# Fixed launcher parameters
const TORPEDOES_PER_VOLLEY: int = 2  # ALWAYS 2
const TUBES_PER_SIDE: int = 2  # 4 port, 4 starboard
const TUBE_SPACING: float = 30.0  # pixels between tubes
const LATERAL_OFFSET: float = 60.0  # pixels from ship center to tubes

# Reload parameters
@export var reload_time: float = 10.0
@export var launch_sequence_delay: float = 0.15  # Faster sequence

# Launch state
var port_tubes_ready: int = TUBES_PER_SIDE
var starboard_tubes_ready: int = TUBES_PER_SIDE
var reload_timers: Dictionary = {}  # "port_0", "starboard_1" -> float

# References
var parent_ship: Node2D
var torpedo_scene = preload("res://Scenes/SmartTorpedo.tscn")

# Launch sequence
var launch_queue: Array = []
var launch_timer: float = 0.0
var current_volley_count: int = 0

# Simultaneous impact configuration
const IMPACT_ARC_DEGREES: float = 160.0  # Total arc for torpedo spread
const BASE_IMPACT_TIME: float = 12.0  # Base time for simultaneous impact

# Debug
@export var debug_enabled: bool = false

func _ready():
	parent_ship = get_parent()
	
	# Generate ID if not provided
	if launcher_id == "":
		launcher_id = "launcher_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# Initialize reload timers
	for i in range(TUBES_PER_SIDE):
		reload_timers["port_%d" % i] = 0.0
		reload_timers["starboard_%d" % i] = 0.0
	
	# Ensure only one trajectory type is selected
	_validate_trajectory_selection()
	
	# Add to group for BattleManager to find
	add_to_group("torpedo_launchers")
	
	print("Torpedo launcher initialized: %s trajectory mode" % get_trajectory_mode_name())

func _validate_trajectory_selection():
	"""Ensure only one trajectory type is selected"""
	var selected_count = 0
	if use_straight_trajectory: selected_count += 1
	if use_multi_angle_trajectory: selected_count += 1
	if use_simultaneous_impact: selected_count += 1
	
	if selected_count != 1:
		# Default to straight if multiple or none selected
		use_straight_trajectory = true
		use_multi_angle_trajectory = false
		use_simultaneous_impact = false
		print("WARNING: Invalid trajectory selection, defaulting to straight")

func get_trajectory_mode_name() -> String:
	if use_straight_trajectory: return "Straight"
	if use_multi_angle_trajectory: return "Multi-Angle"
	if use_simultaneous_impact: return "Simultaneous Impact"
	return "Unknown"

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
			_launch_single_torpedo(launch_data)
			launch_timer = launch_sequence_delay

func fire_torpedo(target: Node2D, count: int = -1):
	"""Main public interface - fire a volley at target"""
	if not is_valid_target(target):
		print("Invalid target provided to torpedo launcher")
		return
	
	var total_ready = port_tubes_ready + starboard_tubes_ready
	if total_ready == 0:
		print("No torpedo tubes ready")
		return
	
	# Always fire full volley (8 torpedoes)
	count = min(TORPEDOES_PER_VOLLEY, total_ready)
	
	#print("\n=== FIRING TORPEDO VOLLEY ===")
	#print("Mode: %s" % get_trajectory_mode_name())
	#print("Target: %s" % target.name)
	#print("Torpedoes: %d" % count)
	
	# Clear any pending launches
	launch_queue.clear()
	current_volley_count = 0
	
	# Prepare launch data based on trajectory type
	if use_simultaneous_impact:
		_prepare_simultaneous_impact_volley(target, count)
	else:
		_prepare_standard_volley(target, count)

func _prepare_standard_volley(target: Node2D, count: int):
	"""Prepare launch queue for straight or multi-angle trajectories"""
	
	# Determine which side to fire from based on target position
	var to_target = target.global_position - global_position
	var ship_right = Vector2.UP.rotated(parent_ship.rotation + PI/2)
	var is_target_starboard = to_target.dot(ship_right) > 0
	
	# Queue torpedoes for launch
	var torpedoes_queued = 0
	
	# Fire from the side facing the target first
	if is_target_starboard:
		torpedoes_queued += _queue_side_torpedoes(target, 1, count - torpedoes_queued)  # Starboard
		torpedoes_queued += _queue_side_torpedoes(target, -1, count - torpedoes_queued)  # Port
	else:
		torpedoes_queued += _queue_side_torpedoes(target, -1, count - torpedoes_queued)  # Port
		torpedoes_queued += _queue_side_torpedoes(target, 1, count - torpedoes_queued)  # Starboard

func _prepare_simultaneous_impact_volley(target: Node2D, count: int):
	"""Prepare launch queue for simultaneous impact pattern"""
	
	# Calculate impact time based on distance
	var distance_to_target = global_position.distance_to(target.global_position)
	var distance_meters = distance_to_target * WorldSettings.meters_per_pixel
	var impact_time = BASE_IMPACT_TIME + (distance_meters / 5000.0)  # Adjust based on distance
	
	# Calculate angle spacing
	var angle_spacing = deg_to_rad(IMPACT_ARC_DEGREES) / float(count - 1) if count > 1 else 0.0
	var start_angle = -deg_to_rad(IMPACT_ARC_DEGREES / 2.0)
	
	# Get ship-to-target bearing for impact angle calculation
	var to_target = (target.global_position - parent_ship.global_position).normalized()
	var base_angle = to_target.angle()
	
	var launch_time = Time.get_ticks_msec() / 1000.0
	
	# Queue all torpedoes with their assigned impact angles
	var torpedo_index = 0
	
	# Alternate between sides for visual balance
	for i in range(TUBES_PER_SIDE):
		# Port tube
		if port_tubes_ready > 0 and torpedo_index < count:
			var impact_angle = base_angle + start_angle + (torpedo_index * angle_spacing)
			_queue_torpedo_with_data(target, -1, i, {
				"impact_time": impact_time,
				"impact_angle": impact_angle,
				"launch_time": launch_time
			})
			torpedo_index += 1
		
		# Starboard tube
		if starboard_tubes_ready > 0 and torpedo_index < count:
			var impact_angle = base_angle + start_angle + (torpedo_index * angle_spacing)
			_queue_torpedo_with_data(target, 1, i, {
				"impact_time": impact_time,
				"impact_angle": impact_angle,
				"launch_time": launch_time
			})
			torpedo_index += 1

func _queue_side_torpedoes(target: Node2D, side: int, max_count: int) -> int:
	"""Queue torpedoes from one side (returns number queued)"""
	var ready_count = starboard_tubes_ready if side == 1 else port_tubes_ready
	var queued = 0
	
	for i in range(TUBES_PER_SIDE):
		if queued >= max_count:
			break
			
		var tube_id = ("starboard_%d" if side == 1 else "port_%d") % i
		if reload_timers[tube_id] == 0.0 and ready_count > 0:
			_queue_torpedo_with_data(target, side, i, {})
			queued += 1
			ready_count -= 1
	
	return queued

func _queue_torpedo_with_data(target: Node2D, side: int, tube_index: int, flight_data: Dictionary):
	"""Add torpedo to launch queue with flight plan data"""
	var tube_id = ("starboard_%d" if side == 1 else "port_%d") % tube_index
	
	launch_queue.append({
		"target": target,
		"side": side,
		"tube_index": tube_index,
		"flight_data": flight_data
	})
	
	# Mark tube as firing
	reload_timers[tube_id] = reload_time
	if side == 1:
		starboard_tubes_ready -= 1
	else:
		port_tubes_ready -= 1

func _launch_single_torpedo(launch_data: Dictionary):
	"""Actually spawn and configure a single torpedo"""
	var target = launch_data.target
	if not torpedo_scene or not is_valid_target(target):
		return
	
	current_volley_count += 1
	
	# Create torpedo instance
	var torpedo = torpedo_scene.instantiate()
	
	# Configure torpedo BEFORE adding to scene tree
	torpedo.set_target(target)
	torpedo.set_launcher(parent_ship)
	torpedo.set_launch_side(launch_data.side)
	
	# Set flight plan based on selected trajectory type
	if use_straight_trajectory:
		torpedo.set_flight_plan("straight")
	elif use_multi_angle_trajectory:
		torpedo.set_flight_plan("multi_angle", {
			"approach_side": launch_data.side
		})
	elif use_simultaneous_impact:
		torpedo.set_flight_plan("simultaneous", launch_data.flight_data)
	
	# Set faction from parent ship
	if "faction" in parent_ship:
		torpedo.faction = parent_ship.faction
	
	# Calculate launch position
	var ship_forward = Vector2.UP.rotated(parent_ship.rotation)
	var ship_right = Vector2.UP.rotated(parent_ship.rotation + PI/2)
	
	var side_offset = ship_right * LATERAL_OFFSET * launch_data.side
	var tube_offset = ship_forward * (launch_data.tube_index - (TUBES_PER_SIDE - 1) * 0.5) * TUBE_SPACING
	
	# Add to scene tree AFTER configuration
	get_tree().root.add_child(torpedo)
	torpedo.global_position = parent_ship.global_position + side_offset + tube_offset
	
	if DebugConfig.should_log("torpedo_init"):
		print("[Launcher] Spawned torpedo %s at %s targeting %s" % [
			torpedo.torpedo_id if "torpedo_id" in torpedo else "unknown",
			torpedo.global_position,
			target.name
		])

func on_tube_reloaded(tube_id: String):
	if tube_id.begins_with("port"):
		port_tubes_ready += 1
	else:
		starboard_tubes_ready += 1
	
	if debug_enabled:
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
		"total_ready": port_tubes_ready + starboard_tubes_ready,
		"reloading": {}
	}
	
	for tube_id in reload_timers:
		if reload_timers[tube_id] > 0:
			status.reloading[tube_id] = reload_timers[tube_id]
	
	return status

# Battle integration methods (for BattleManager)
func start_battle_firing():
	"""Called by BattleManager to enable auto-firing"""
	# Not used in current implementation since auto_volley is false
	pass
	
func stop_battle_firing():
	"""Called by BattleManager to stop any pending launches"""
	launch_queue.clear()
	current_volley_count = 0

# Debug visualization
func _draw():
	if not debug_enabled:
		return
	
	# Draw tube positions
	var ship_forward = Vector2.UP.rotated(parent_ship.rotation if parent_ship else 0.0)
	var ship_right = Vector2.UP.rotated((parent_ship.rotation if parent_ship else 0.0) + PI/2)
	
	for i in range(TUBES_PER_SIDE):
		# Port tubes
		var port_offset = ship_right * -LATERAL_OFFSET
		var tube_offset = ship_forward * (i - (TUBES_PER_SIDE - 1) * 0.5) * TUBE_SPACING
		var port_pos = port_offset + tube_offset
		var port_ready = reload_timers["port_%d" % i] == 0.0
		draw_circle(port_pos, 5, Color.GREEN if port_ready else Color.RED)
		
		# Starboard tubes
		var starboard_offset = ship_right * LATERAL_OFFSET
		var starboard_pos = starboard_offset + tube_offset
		var starboard_ready = reload_timers["starboard_%d" % i] == 0.0
		draw_circle(starboard_pos, 5, Color.GREEN if starboard_ready else Color.RED)

func reset_all_tubes():
	port_tubes_ready = TUBES_PER_SIDE
	starboard_tubes_ready = TUBES_PER_SIDE
	for tube_id in reload_timers:
		reload_timers[tube_id] = 0.0
	launch_queue.clear()
	current_volley_count = 0
