# Scripts/Systems/BatchMPCManager.gd
extends Node
class_name BatchMPCManager

# Update scheduling
var update_timer: float = 0.0
var base_update_interval: float = 1.0  # 1 Hz baseline
var current_update_interval: float = 1.0

# System references  
var trajectory_planner: TrajectoryPlanner

# Batch state
var current_batch_size: int = 0
var last_update_time: float = 0.0

# Signals for event-based architecture
signal waypoints_updated(torpedo_id: String, waypoints: Array)
signal batch_update_started()
signal batch_update_completed(torpedo_count: int)

# Time dilation support
var use_real_time_updates: bool = true  # For tuning mode

func _ready():
	trajectory_planner = get_node("/root/TrajectoryPlannerSystem")
	set_process(true)

func _process(delta):
	# Use real-world time for updates during time dilation
	var effective_delta = delta
	if use_real_time_updates and Engine.time_scale != 1.0:
		effective_delta = delta / Engine.time_scale
	
	update_timer += effective_delta
	
	if update_timer >= current_update_interval:
		update_timer = 0.0
		execute_batch_update()

func execute_batch_update():
	emit_signal("batch_update_started")
	var start_time = Time.get_ticks_usec()
	
	# Collect all valid torpedo states (with zero-trust validation)
	var torpedo_states = collect_and_validate_torpedo_states()
	
	if torpedo_states.is_empty():
		emit_signal("batch_update_completed", 0)
		return
	
	current_batch_size = torpedo_states.size()
	
	# Calculate dynamic update rate based on closest time-to-impact
	var min_time_to_impact = calculate_minimum_time_to_impact(torpedo_states)
	current_update_interval = calculate_update_interval(min_time_to_impact)
	
	# Send batch to GPU via TrajectoryPlanner
	var gpu_results = trajectory_planner.generate_waypoints_batch(torpedo_states)
	
	# Apply results to torpedoes
	apply_batch_results(gpu_results, torpedo_states)
	
	# Performance tracking
	var batch_time = (Time.get_ticks_usec() - start_time) / 1000.0
	last_update_time = batch_time
	
	emit_signal("batch_update_completed", current_batch_size)

func collect_and_validate_torpedo_states() -> Array:
	var valid_states = []
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	
	for torpedo in torpedoes:
		# Zero-trust validation
		if not is_instance_valid(torpedo):
			continue
		if not torpedo.is_inside_tree():
			continue
		if torpedo.get("marked_for_death"):
			continue
			
		# Validate physics state
		var pos = torpedo.global_position
		var vel = torpedo.get("velocity_mps")
		if not vel or vel.length() > 1000000:  # Sanity check
			continue
			
		# Package state for GPU
		var state = {
			"torpedo_ref": torpedo,
			"torpedo_id": torpedo.get("torpedo_id"),
			"position": pos,
			"velocity": vel,
			"orientation": torpedo.get("orientation"),
			"max_acceleration": torpedo.get("max_acceleration"),
			"max_rotation_rate": torpedo.get("max_rotation_rate"),
			"target_position": get_target_position(torpedo),
			"target_velocity": get_target_velocity(torpedo),
			"flight_plan_type": torpedo.get("flight_plan_type"),
			"flight_plan_data": torpedo.get("flight_plan_data")
		}
		
		valid_states.append(state)
	
	return valid_states

func calculate_minimum_time_to_impact(torpedo_states: Array) -> float:
	var min_time = INF
	
	for state in torpedo_states:
		var to_target = state.target_position - state.position
		var distance = to_target.length() * WorldSettings.meters_per_pixel
		var closing_speed = -state.velocity.dot(to_target.normalized())
		
		if closing_speed > 0:
			var time_to_impact = distance / closing_speed
			min_time = min(min_time, time_to_impact)
	
	return min_time

func calculate_update_interval(time_to_impact: float) -> float:
	# Dynamic update rate: 1-3 Hz based on urgency
	if time_to_impact >= 15.0:
		return 1.0  # 1 Hz for distant targets
	elif time_to_impact >= 10.0:
		return 0.5  # 2 Hz for medium range
	elif time_to_impact >= 5.0:
		return 0.33  # 3 Hz for close range
	else:
		return 0.33  # Cap at 3 Hz even in terminal phase

func get_target_position(torpedo: Node2D) -> Vector2:
	var target = torpedo.get("target_node")
	if target and is_instance_valid(target):
		return target.global_position
	return torpedo.global_position + Vector2(1000, 0)  # Default forward

func get_target_velocity(torpedo: Node2D) -> Vector2:
	var target = torpedo.get("target_node")
	if target and is_instance_valid(target):
		if target.has_method("get_velocity_mps"):
			return target.get_velocity_mps()
	return Vector2.ZERO

func apply_batch_results(gpu_results: Array, torpedo_states: Array):
	# Protected waypoint count (current + next 2)
	var protected_count = 3
	
	for i in range(min(gpu_results.size(), torpedo_states.size())):
		var result = gpu_results[i]
		var state = torpedo_states[i]
		var torpedo = state.torpedo_ref
		
		if not is_instance_valid(torpedo):
			continue
			
		# Apply waypoint update to torpedo
		if torpedo.has_method("apply_waypoint_update"):
			torpedo.apply_waypoint_update(result.waypoints, protected_count)
			
			# Emit signal for visualization
			emit_signal("waypoints_updated", state.torpedo_id, result.waypoints)
