# Scripts/Systems/TrajectoryPlanner.gd
extends Node
class_name TrajectoryPlanner

# GPU compute resources
var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Error handling
var gpu_available: bool = false
var initialization_error: String = ""

# Physics validation parameters
const TURN_RADIUS_SAFETY_FACTOR: float = 1.5  # 50% safety margin
const MIN_WAYPOINT_SPACING_METERS: float = 100.0
const FLIP_DURATION_SECONDS: float = 2.5
const VELOCITY_CHANGE_RATE_LIMIT: float = 2000.0  # m/s per second max

# Waypoint density control
var waypoint_density_threshold: float = 0.2  # From manual tuning

func _ready():
	initialize_gpu_compute()
	
	if not gpu_available:
		push_error("GPU Compute Required - This game requires GPU compute shaders")
		get_tree().quit()

func initialize_gpu_compute():
	# Create rendering device
	rd = RenderingServer.create_local_rendering_device()
	
	if not rd:
		initialization_error = "Failed to create rendering device - GPU compute not supported"
		return
	
	# Load and compile shader
	var shader_file = load("res://Shaders/trajectory_planning_v9.glsl")
	if not shader_file:
		initialization_error = "Failed to load trajectory planning shader"
		return
		
	var shader_spirv = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	
	if not shader or shader == RID():
		initialization_error = "Failed to create shader from SPIR-V"
		return
		
	# Create compute pipeline
	pipeline = rd.compute_pipeline_create(shader)
	
	if not pipeline or pipeline == RID():
		initialization_error = "Failed to create compute pipeline"
		return
	
	gpu_available = true
	print("TrajectoryPlanner: GPU compute initialized successfully")

func generate_waypoints_batch(torpedo_states: Array) -> Array:
	if not gpu_available:
		push_error("TrajectoryPlanner: GPU not available!")
		return []
	
	var start_time = Time.get_ticks_usec()
	
	# Get tuned parameters from singleton
	var params = TuningParams.get_current_parameters()
	
	# Prepare GPU buffers
	var gpu_input = prepare_gpu_input(torpedo_states, params)
	var gpu_output = execute_gpu_computation(gpu_input)
	
	# Process results
	var results = []
	for i in range(torpedo_states.size()):
		var waypoints = extract_waypoints_for_torpedo(gpu_output, i)
		waypoints = apply_adaptive_waypoint_density(waypoints, params.waypoint_density_threshold)
		
		# Validate physics
		if not validate_trajectory_physics(waypoints):
			# If invalid, generate emergency straight-line waypoints
			waypoints = generate_emergency_waypoints(torpedo_states[i])
		
		results.append({
			"torpedo_id": torpedo_states[i].torpedo_id,
			"waypoints": waypoints
		})
	
	var compute_time = (Time.get_ticks_usec() - start_time) / 1000.0
	if compute_time > 10.0:
		print("TrajectoryPlanner: Slow computation - %.1f ms for %d torpedoes" % [compute_time, torpedo_states.size()])
	
	return results

func prepare_gpu_input(torpedo_states: Array, params: Dictionary) -> Dictionary:
	# Implementation would prepare data for GPU
	# This is a placeholder - actual implementation would format data for shader
	return {
		"torpedo_states": torpedo_states,
		"parameters": params
	}

func execute_gpu_computation(gpu_input: Dictionary) -> Array:
	# This would execute the GPU shader and return results
	# Placeholder implementation
	var results = []
	
	# For now, generate simple waypoints as placeholder
	for state in gpu_input.torpedo_states:
		var waypoints = []
		var to_target = state.target_position - state.position
		var distance = to_target.length()
		
		# Generate waypoints along path
		for i in range(5):
			var t = float(i) / 4.0
			var waypoint = TorpedoBase.Waypoint.new()
			waypoint.position = state.position + to_target * t
			waypoint.velocity_target = 2000.0  # Target velocity
			waypoint.velocity_tolerance = 500.0
			waypoint.maneuver_type = "cruise"
			waypoint.thrust_limit = 1.0
			waypoints.append(waypoint)
		
		results.append(waypoints)
	
	return results

func extract_waypoints_for_torpedo(gpu_output: Array, index: int) -> Array:
	if index < gpu_output.size():
		return gpu_output[index]
	return []

func apply_adaptive_waypoint_density(waypoints: Array, threshold: float) -> Array:
	"""Subdivide waypoints based on velocity changes"""
	if waypoints.size() < 2:
		return waypoints
	
	waypoint_density_threshold = TuningParams.get_parameter("universal.waypoint_density_threshold", 0.2)
	
	var densified = []
	densified.append(waypoints[0])
	
	for i in range(1, waypoints.size()):
		var wp1 = waypoints[i-1]
		var wp2 = waypoints[i]
		
		# Check velocity change
		var vel_change = abs(wp2.velocity_target - wp1.velocity_target) / max(wp1.velocity_target, 100.0)
		var needs_subdivision = vel_change > threshold
		
		if needs_subdivision:
			# Add intermediate waypoints
			var subdivisions = ceil(vel_change / threshold)
			subdivisions = min(subdivisions, 5)  # Cap at 5
			
			for j in range(1, subdivisions):
				var t = float(j) / subdivisions
				var mid_waypoint = interpolate_waypoints(wp1, wp2, t)
				densified.append(mid_waypoint)
		
		densified.append(wp2)
	
	# Ensure we don't exceed max waypoints
	var max_waypoints = TuningParams.get_parameter("max_waypoints", 100)
	if densified.size() > max_waypoints:
		densified = reduce_waypoint_count(densified, max_waypoints)
	
	return densified

func interpolate_waypoints(wp1: TorpedoBase.Waypoint, wp2: TorpedoBase.Waypoint, t: float) -> TorpedoBase.Waypoint:
	var waypoint = TorpedoBase.Waypoint.new()
	waypoint.position = wp1.position.lerp(wp2.position, t)
	waypoint.velocity_target = lerp(wp1.velocity_target, wp2.velocity_target, t)
	waypoint.velocity_tolerance = lerp(wp1.velocity_tolerance, wp2.velocity_tolerance, t)
	waypoint.thrust_limit = lerp(wp1.thrust_limit, wp2.thrust_limit, t)
	waypoint.maneuver_type = wp1.maneuver_type if t < 0.5 else wp2.maneuver_type
	return waypoint

func reduce_waypoint_count(waypoints: Array, max_count: int) -> Array:
	# Simple reduction - keep first, last, and evenly spaced middle points
	if waypoints.size() <= max_count:
		return waypoints
		
	var reduced = []
	var step = float(waypoints.size() - 1) / float(max_count - 1)
	
	for i in range(max_count):
		var index = int(i * step)
		reduced.append(waypoints[index])
	
	return reduced

func validate_trajectory_physics(waypoints: Array) -> bool:
	"""Validate that trajectory is physically achievable"""
	
	if waypoints.size() < 2:
		return false
	
	var validation_passed = true
	
	for i in range(waypoints.size() - 1):
		var wp1 = waypoints[i]
		var wp2 = waypoints[i + 1]
		
		# Check waypoint spacing
		var distance = wp1.position.distance_to(wp2.position) * WorldSettings.meters_per_pixel
		if distance < MIN_WAYPOINT_SPACING_METERS:
			validation_passed = false
			continue
		
		# Check velocity change feasibility
		var time_between = estimate_time_between_waypoints(wp1, wp2)
		var velocity_change = abs(wp2.velocity_target - wp1.velocity_target)
		var max_velocity_change = wp1.max_acceleration * time_between
		
		if velocity_change > max_velocity_change * 1.1:  # 10% tolerance
			validation_passed = false
	
	return validation_passed

func estimate_time_between_waypoints(wp1: TorpedoBase.Waypoint, wp2: TorpedoBase.Waypoint) -> float:
	var distance = wp1.position.distance_to(wp2.position) * WorldSettings.meters_per_pixel
	var avg_velocity = (wp1.velocity_target + wp2.velocity_target) / 2.0
	return distance / max(avg_velocity, 100.0)

func generate_emergency_waypoints(torpedo_state: Dictionary) -> Array:
	# Generate simple straight-line waypoints as fallback
	var waypoints = []
	var to_target = torpedo_state.target_position - torpedo_state.position
	
	for i in range(5):
		var t = float(i) / 4.0
		var waypoint = TorpedoBase.Waypoint.new()
		waypoint.position = torpedo_state.position + to_target * t
		waypoint.velocity_target = 2000.0
		waypoint.velocity_tolerance = 500.0
		waypoint.maneuver_type = "cruise"
		waypoint.thrust_limit = 1.0
		waypoints.append(waypoint)
	
	return waypoints
