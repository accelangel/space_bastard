# Scripts/Systems/TrajectoryPlanner.gd
extends Node
class_name TrajectoryPlanner

# GPU compute resources
var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Buffer management
var input_buffer: RID
var output_buffer: RID
var params_buffer: RID
var uniform_set: RID

# Error handling
var gpu_available: bool = false
var initialization_error: String = ""

# Physics validation parameters
const TURN_RADIUS_SAFETY_FACTOR: float = 1.5
const MIN_WAYPOINT_SPACING_METERS: float = 100.0
const FLIP_DURATION_SECONDS: float = 2.5
const VELOCITY_CHANGE_RATE_LIMIT: float = 2000.0
const MAX_WAYPOINTS_PER_TORPEDO: int = 20

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
	print("TrajectoryPlanner: GPU compute initialized successfully - Device: %s" % rd.get_device_name())

func generate_waypoints_batch(torpedo_states: Array) -> Array:
	if not gpu_available:
		push_error("TrajectoryPlanner: GPU not available!")
		return []
	
	if torpedo_states.is_empty():
		return []
	
	var start_time = Time.get_ticks_usec()
	
	# Get tuned parameters
	var params = TuningParams.get_current_parameters()
	
	# Prepare GPU computation
	var batch_size = torpedo_states.size()
	_create_gpu_buffers(torpedo_states, params)
	
	# Execute GPU computation
	_dispatch_gpu_compute(batch_size)
	
	# Read back results
	var results = _read_gpu_results(batch_size)
	
	# Process and validate results
	var processed_results = []
	for i in range(batch_size):
		var raw_waypoints = results[i]
		var waypoints = _process_raw_waypoints(raw_waypoints, params)
		
		# Validate physics
		if not validate_trajectory_physics(waypoints, torpedo_states[i]):
			waypoints = generate_emergency_waypoints(torpedo_states[i])
		
		processed_results.append({
			"torpedo_id": torpedo_states[i].torpedo_id,
			"waypoints": waypoints
		})
	
	# Cleanup
	_cleanup_gpu_buffers()
	
	var compute_time = (Time.get_ticks_usec() - start_time) / 1000.0
	if compute_time > 10.0:
		print("TrajectoryPlanner: Slow computation - %.1f ms for %d torpedoes" % [compute_time, batch_size])
	
	return processed_results

func _create_gpu_buffers(torpedo_states: Array, params: Dictionary):
	var batch_size = torpedo_states.size()
	
	# Prepare input data - FIXED DATA ALIGNMENT
	var input_data = PackedFloat32Array()
	var flight_plan_data = PackedFloat32Array()
	
	for state in torpedo_states:
		# Basic torpedo state (8 floats)
		input_data.append(state.position.x)
		input_data.append(state.position.y)
		input_data.append(state.velocity.x)
		input_data.append(state.velocity.y)
		input_data.append(state.orientation)
		input_data.append(0.0) # angular velocity placeholder
		input_data.append(state.max_acceleration)
		input_data.append(state.max_rotation_rate)
		
		# Target state (4 floats) - THIS WAS MISSING!
		input_data.append(state.target_position.x)
		input_data.append(state.target_position.y)
		input_data.append(state.target_velocity.x)
		input_data.append(state.target_velocity.y)
		
		# Continuation point (4 floats)
		input_data.append(state.continuation_position.x)
		input_data.append(state.continuation_position.y)
		input_data.append(state.continuation_velocity)
		input_data.append(float(state.current_waypoint_index))
		
		# Flight plan (4 floats)
		var plan_type = 0
		match state.flight_plan_type:
			"straight": plan_type = 0
			"multi_angle": plan_type = 1
			"simultaneous": plan_type = 2
			
		flight_plan_data.append(float(plan_type))
		flight_plan_data.append(state.flight_plan_data.get("side", 0.0))
		flight_plan_data.append(state.flight_plan_data.get("impact_time", 0.0))
		flight_plan_data.append(state.flight_plan_data.get("impact_angle", 0.0))
	
	# Prepare parameters buffer
	var params_data = PackedFloat32Array()
	
	# Universal parameters
	params_data.append(params.layer1.universal.waypoint_density_threshold)
	params_data.append(float(params.layer1.universal.max_waypoints))
	params_data.append(WorldSettings.meters_per_pixel)
	params_data.append(float(batch_size))
	
	# Straight trajectory params
	params_data.append(params.layer1.straight.lateral_separation)
	params_data.append(params.layer1.straight.convergence_delay)
	params_data.append(params.layer1.straight.initial_boost_duration)
	params_data.append(0.0) # padding
	
	# Multi-angle params
	params_data.append(params.layer1.multi_angle.flip_burn_threshold)
	params_data.append(params.layer1.multi_angle.deceleration_target)
	params_data.append(params.layer1.multi_angle.arc_distance)
	params_data.append(params.layer1.multi_angle.arc_start)
	params_data.append(params.layer1.multi_angle.arc_peak)
	params_data.append(params.layer1.multi_angle.final_approach)
	params_data.append(0.0) # padding
	params_data.append(0.0) # padding
	
	# Simultaneous impact params
	params_data.append(params.layer1.simultaneous.flip_burn_threshold)
	params_data.append(params.layer1.simultaneous.deceleration_target)
	params_data.append(params.layer1.simultaneous.fan_out_rate)
	params_data.append(params.layer1.simultaneous.fan_duration)
	params_data.append(params.layer1.simultaneous.converge_start)
	params_data.append(params.layer1.simultaneous.converge_aggression)
	params_data.append(0.0) # padding
	params_data.append(0.0) # padding
	
	# Create GPU buffers - FIXED SIZE CALCULATION
	# 16 floats for torpedo data (including target) + 4 floats for flight plan = 20 floats total
	var input_size = (16 + 4) * batch_size * 4  # bytes
	
	# Combine input and flight plan data
	var combined_data = input_data.to_byte_array()
	combined_data.append_array(flight_plan_data.to_byte_array())
	
	input_buffer = rd.storage_buffer_create(input_size, combined_data)
	params_buffer = rd.storage_buffer_create(params_data.size() * 4, params_data.to_byte_array())
	
	# Output buffer for waypoints
	var waypoint_size = 8 * 4  # 8 floats per waypoint
	var output_size = waypoint_size * MAX_WAYPOINTS_PER_TORPEDO * batch_size
	output_buffer = rd.storage_buffer_create(output_size)

func _dispatch_gpu_compute(batch_size: int):
	# Create uniform set
	var bindings = []
	
	# Binding 0: Input buffer
	var input_uniform = RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_uniform.binding = 0
	input_uniform.add_id(input_buffer)
	bindings.append(input_uniform)
	
	# Binding 1: Parameters buffer
	var params_uniform = RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 1
	params_uniform.add_id(params_buffer)
	bindings.append(params_uniform)
	
	# Binding 2: Output buffer
	var output_uniform = RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output_uniform.binding = 2
	output_uniform.add_id(output_buffer)
	bindings.append(output_uniform)
	
	uniform_set = rd.uniform_set_create(bindings, shader, 0)
	
	# Dispatch compute
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Calculate workgroups (64 threads per group)
	var workgroups = int(ceil(float(batch_size) / 64.0))
	rd.compute_list_dispatch(compute_list, workgroups, 1, 1)
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()

func _read_gpu_results(batch_size: int) -> Array:
	var output_bytes = rd.buffer_get_data(output_buffer)
	var output_array = output_bytes.to_float32_array()
	
	var results = []
	var floats_per_waypoint = 8
	var waypoints_per_torpedo = MAX_WAYPOINTS_PER_TORPEDO
	
	for i in range(batch_size):
		var torpedo_waypoints = []
		var base_idx = i * waypoints_per_torpedo * floats_per_waypoint
		
		for j in range(waypoints_per_torpedo):
			var wp_idx = base_idx + j * floats_per_waypoint
			
			# Check if waypoint is valid (position != 0,0)
			if output_array[wp_idx] == 0.0 and output_array[wp_idx + 1] == 0.0:
				break  # No more waypoints for this torpedo
			
			torpedo_waypoints.append({
				"position": Vector2(output_array[wp_idx], output_array[wp_idx + 1]),
				"velocity_target": output_array[wp_idx + 2],
				"velocity_tolerance": output_array[wp_idx + 3],
				"maneuver_type": int(output_array[wp_idx + 4]),
				"thrust_limit": output_array[wp_idx + 5]
			})
		
		results.append(torpedo_waypoints)
	
	return results

func _process_raw_waypoints(raw_waypoints: Array, params: Dictionary) -> Array:
	var waypoints = []
	var density_threshold = params.waypoint_density_threshold
	
	for i in range(raw_waypoints.size()):
		var raw = raw_waypoints[i]
		var waypoint = TorpedoBase.Waypoint.new()
		
		waypoint.position = raw.position
		waypoint.velocity_target = raw.velocity_target
		waypoint.velocity_tolerance = raw.velocity_tolerance
		waypoint.thrust_limit = raw.thrust_limit
		
		# Map maneuver types
		match int(raw.maneuver_type):
			0: waypoint.maneuver_type = "cruise"
			1: waypoint.maneuver_type = "boost"
			2: waypoint.maneuver_type = "flip"
			3: waypoint.maneuver_type = "burn"
			4: waypoint.maneuver_type = "curve"
			5: waypoint.maneuver_type = "terminal"
			_: waypoint.maneuver_type = "cruise"
		
		waypoints.append(waypoint)
	
	# Apply adaptive density
	return apply_adaptive_waypoint_density(waypoints, density_threshold)

func apply_adaptive_waypoint_density(waypoints: Array, threshold: float) -> Array:
	if waypoints.size() < 2:
		return waypoints
	
	var densified = []
	densified.append(waypoints[0])
	
	for i in range(1, waypoints.size()):
		var wp1 = waypoints[i-1]
		var wp2 = waypoints[i]
		
		# Check velocity change
		var vel_change = abs(wp2.velocity_target - wp1.velocity_target) / max(wp1.velocity_target, 100.0)
		var needs_subdivision = vel_change > threshold
		
		# Check for maneuver type changes
		if wp1.maneuver_type != wp2.maneuver_type:
			needs_subdivision = true
		
		if needs_subdivision:
			var subdivisions = min(ceil(vel_change / threshold), 5)
			
			for j in range(1, subdivisions):
				var t = float(j) / subdivisions
				var mid_waypoint = interpolate_waypoints(wp1, wp2, t)
				densified.append(mid_waypoint)
		
		densified.append(wp2)
	
	return densified

func interpolate_waypoints(wp1: TorpedoBase.Waypoint, wp2: TorpedoBase.Waypoint, t: float) -> TorpedoBase.Waypoint:
	var waypoint = TorpedoBase.Waypoint.new()
	waypoint.position = wp1.position.lerp(wp2.position, t)
	waypoint.velocity_target = lerp(wp1.velocity_target, wp2.velocity_target, t)
	waypoint.velocity_tolerance = lerp(wp1.velocity_tolerance, wp2.velocity_tolerance, t)
	waypoint.thrust_limit = lerp(wp1.thrust_limit, wp2.thrust_limit, t)
	waypoint.maneuver_type = wp1.maneuver_type if t < 0.5 else wp2.maneuver_type
	waypoint.max_acceleration = wp1.max_acceleration
	return waypoint

func validate_trajectory_physics(waypoints: Array, torpedo_state: Dictionary) -> bool:
	if waypoints.size() < 2:
		return false
	
	var max_acceleration = torpedo_state.max_acceleration
	var current_velocity = torpedo_state.velocity.length()
	
	# Check if initial velocity is too high for first waypoint
	if current_velocity > 50000.0:  # 50 km/s threshold
		print("TrajectoryPlanner: Initial velocity too high: %.1f m/s" % current_velocity)
		return false
	
	for i in range(waypoints.size() - 1):
		var wp1 = waypoints[i]
		var wp2 = waypoints[i + 1]
		
		# Check waypoint spacing
		var distance = wp1.position.distance_to(wp2.position) * WorldSettings.meters_per_pixel
		if distance < MIN_WAYPOINT_SPACING_METERS:
			return false
		
		# Check velocity change feasibility
		var time_between = estimate_time_between_waypoints(wp1, wp2)
		var velocity_change = abs(wp2.velocity_target - wp1.velocity_target)
		var max_velocity_change = max_acceleration * time_between
		
		if velocity_change > max_velocity_change * 1.1:  # 10% tolerance
			return false
		
		# Check turn radius for high-speed maneuvers
		if i > 0 and wp1.velocity_target > 5000.0:  # High speed threshold
			var wp0 = waypoints[i - 1]
			var dir1 = (wp1.position - wp0.position).normalized()
			var dir2 = (wp2.position - wp1.position).normalized()
			var angle_change = acos(clamp(dir1.dot(dir2), -1.0, 1.0))
			
			if angle_change > deg_to_rad(5):  # Significant turn
				var required_radius = distance / (2 * sin(angle_change / 2))
				var actual_radius = (wp1.velocity_target * wp1.velocity_target) / max_acceleration
				
				if actual_radius > required_radius * TURN_RADIUS_SAFETY_FACTOR:
					return false
	
	return true

func estimate_time_between_waypoints(wp1: TorpedoBase.Waypoint, wp2: TorpedoBase.Waypoint) -> float:
	var distance = wp1.position.distance_to(wp2.position) * WorldSettings.meters_per_pixel
	var avg_velocity = (wp1.velocity_target + wp2.velocity_target) / 2.0
	
	# Account for acceleration/deceleration
	var vel_change = abs(wp2.velocity_target - wp1.velocity_target)
	var accel_time = vel_change / wp1.max_acceleration if wp1.max_acceleration > 0 else 0.0
	
	var cruise_time = distance / max(avg_velocity, 100.0)
	return max(cruise_time, accel_time)

func generate_emergency_waypoints(torpedo_state: Dictionary) -> Array:
	var waypoints = []
	var to_target = torpedo_state.target_position - torpedo_state.position
	var distance = to_target.length()
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Simple straight line with velocity management
	var current_speed = torpedo_state.velocity.length()
	var needs_deceleration = current_speed > 5000.0
	
	# Calculate appropriate waypoint count based on distance
	var waypoint_count = max(3, min(10, int(distance_meters / 1000.0)))  # 1 waypoint per km
	
	for i in range(waypoint_count):
		var t = float(i) / float(waypoint_count - 1)
		var waypoint = TorpedoBase.Waypoint.new()
		waypoint.position = torpedo_state.position + to_target * t
		
		if needs_deceleration and i < 2:
			waypoint.velocity_target = lerp(current_speed, 2000.0, t * 2)
			waypoint.maneuver_type = "burn"
		else:
			waypoint.velocity_target = 2000.0
			waypoint.maneuver_type = "cruise"
		
		waypoint.velocity_tolerance = 500.0
		waypoint.thrust_limit = 1.0
		waypoint.max_acceleration = torpedo_state.max_acceleration
		waypoints.append(waypoint)
	
	return waypoints

func _cleanup_gpu_buffers():
	if input_buffer.is_valid():
		rd.free_rid(input_buffer)
	if params_buffer.is_valid():
		rd.free_rid(params_buffer)
	if output_buffer.is_valid():
		rd.free_rid(output_buffer)
	if uniform_set.is_valid():
		rd.free_rid(uniform_set)
