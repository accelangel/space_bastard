# Scripts/Systems/MPCController.gd
class_name MPCController
extends RefCounted

# MPC Configuration
const NEAR_HORIZON_TIME: float = 30.0  # 30 seconds of detailed planning
const NEAR_HORIZON_DT: float = 0.1     # 0.1s resolution for near future
const FAR_HORIZON_DT: float = 1.0      # 1.0s resolution for far future
const MAX_HORIZON_TIME: float = 480.0  # 8 minutes maximum

# Trajectory representation
class Trajectory:
	var states: Array = []  # Array of state vectors [position, velocity, orientation, angular_vel]
	var controls: Array = [] # Array of control vectors [thrust_magnitude, rotation_rate]
	var timestamps: Array = [] # Time for each state
	var cost: float = INF
	
	func get_state_at_time(t: float) -> Dictionary:
		# Find the state at given time using interpolation
		for i in range(timestamps.size() - 1):
			if t >= timestamps[i] and t <= timestamps[i + 1]:
				var alpha = (t - timestamps[i]) / (timestamps[i + 1] - timestamps[i])
				return interpolate_states(states[i], states[i + 1], alpha)
		return {}
	
	func interpolate_states(s1: Dictionary, s2: Dictionary, alpha: float) -> Dictionary:
		return {
			"position": s1.position.lerp(s2.position, alpha),
			"velocity": s1.velocity.lerp(s2.velocity, alpha),
			"orientation": lerp_angle(s1.orientation, s2.orientation, alpha),
			"angular_velocity": lerp(s1.angular_velocity, s2.angular_velocity, alpha)
		}

# Physical constraints
var max_acceleration: float = 490.5  # 50G in m/s²
var max_rotation_rate: float = deg_to_rad(1080.0)  # 3 rotations/second
var max_speed: float = 200000.0  # Will be removed later, but for now...

# Cost function weights (will be tuned)
var cost_weights: Dictionary = {
	"distance": 1.0,
	"control": 0.1,
	"alignment": 0.5,
	"type_specific": 1.0
}

# Current best trajectory
var current_trajectory: Trajectory

# Debug
var debug_enabled: bool = false

func _init():
	current_trajectory = Trajectory.new()

# Main MPC update function
func update_trajectory(
	current_state: Dictionary,
	target_state: Dictionary,
	trajectory_type: String,
	type_params: Dictionary = {},
	delta: float = 0.1
) -> Dictionary:
	"""
	Main MPC update - returns desired control for next timestep
	current_state: {position, velocity, orientation, angular_velocity}
	target_state: {position, velocity}
	trajectory_type: "straight", "multi_angle", "simultaneous"
	type_params: Type-specific parameters (approach_side, impact_time, etc.)
	"""
	
	# Generate trajectory candidates
	var candidates = generate_trajectory_candidates(
		current_state, target_state, trajectory_type, type_params
	)
	
	# Evaluate each candidate
	var best_trajectory = null
	var best_cost = INF
	
	for candidate in candidates:
		var cost = evaluate_trajectory(
			candidate, target_state, trajectory_type, type_params
		)
		if cost < best_cost:
			best_cost = cost
			best_trajectory = candidate
	
	# Update current trajectory
	if best_trajectory:
		current_trajectory = best_trajectory
	
	# Return first control action
	if current_trajectory.controls.size() > 0:
		return current_trajectory.controls[0]
	else:
		# Fallback: simple proportional control toward target
		var to_target = target_state.position - current_state.position
		var desired_orientation = to_target.angle()
		return {
			"thrust": max_acceleration,
			"rotation_rate": clamp(
				angle_difference(current_state.orientation, desired_orientation),
				-max_rotation_rate, max_rotation_rate
			)
		}

func generate_trajectory_candidates(
	current_state: Dictionary,
	target_state: Dictionary,
	trajectory_type: String,
	type_params: Dictionary
) -> Array:
	"""Generate candidate trajectories based on type and current trajectory"""
	
	var candidates = []
	
	# Always include the shifted current trajectory as first candidate
	if current_trajectory.states.size() > 1:
		var shifted = shift_trajectory_forward(current_trajectory, 0.1)
		candidates.append(shifted)
	
	# Generate type-specific templates
	match trajectory_type:
		"straight":
			candidates.append_array(generate_straight_templates(
				current_state, target_state
			))
		"multi_angle":
			candidates.append_array(generate_multi_angle_templates(
				current_state, target_state, type_params.get("approach_side", 1)
			))
		"simultaneous":
			candidates.append_array(generate_simultaneous_templates(
				current_state, target_state, 
				type_params.get("impact_time", 10.0),
				type_params.get("impact_angle", 0.0)
			))
	
	return candidates

func generate_straight_templates(
	current_state: Dictionary,
	target_state: Dictionary
) -> Array:
	"""Generate straight intercept trajectory templates"""
	
	var templates = []
	
	# Calculate basic intercept
	var intercept_time = calculate_intercept_time(
		current_state.position, current_state.velocity,
		target_state.position, target_state.velocity,
		max_speed
	)
	
	if intercept_time <= 0 or intercept_time > MAX_HORIZON_TIME:
		intercept_time = 10.0  # Default fallback
	
	# Generate variations with different thrust profiles
	var thrust_variations = [0.8, 0.9, 1.0]  # 80%, 90%, 100% thrust
	var angle_variations = [-5, 0, 5]  # degrees offset
	
	for thrust_factor in thrust_variations:
		for angle_offset in angle_variations:
			var template = generate_single_trajectory(
				current_state, target_state, intercept_time,
				thrust_factor * max_acceleration,
				deg_to_rad(angle_offset),
				"straight"
			)
			templates.append(template)
	
	return templates

func generate_multi_angle_templates(
	current_state: Dictionary,
	target_state: Dictionary,
	approach_side: int
) -> Array:
	"""Generate multi-angle approach templates"""
	
	var templates = []
	
	# Calculate base intercept time
	var base_time = calculate_intercept_time(
		current_state.position, current_state.velocity,
		target_state.position, target_state.velocity,
		max_speed
	)
	
	# Multi-angle needs more time for the arc
	var intercept_time = base_time * 1.3
	
	# Generate templates with different arc aggressiveness
	var arc_factors = [0.3, 0.4, 0.5]  # How much to arc
	
	for arc_factor in arc_factors:
		var template = generate_arc_trajectory(
			current_state, target_state, intercept_time,
			approach_side, arc_factor
		)
		templates.append(template)
	
	return templates

func generate_simultaneous_templates(
	current_state: Dictionary,
	target_state: Dictionary,
	impact_time: float,
	assigned_angle: float
) -> Array:
	"""Generate simultaneous impact templates"""
	
	var templates = []
	
	# Time remaining to impact
	var time_to_impact = impact_time
	
	# Generate templates with different convergence strategies
	var convergence_starts = [0.6, 0.7, 0.8]  # When to start converging (fraction of flight)
	
	for convergence_start in convergence_starts:
		var template = generate_fan_converge_trajectory(
			current_state, target_state, time_to_impact,
			assigned_angle, convergence_start
		)
		templates.append(template)
	
	return templates

func generate_single_trajectory(
	start_state: Dictionary,
	target_state: Dictionary,
	flight_time: float,
	thrust: float,
	initial_angle_offset: float,
	trajectory_type: String
) -> Trajectory:
	"""Generate a single trajectory with given parameters"""
	
	var trajectory = Trajectory.new()
	var current_state = start_state.duplicate(true)
	
	# Build time array with sliding window resolution
	var times = build_time_array(flight_time)
	
	# Initial control adjustment
	var to_target = target_state.position - current_state.position
	var base_angle = to_target.angle()
	var desired_orientation = base_angle + initial_angle_offset
	
	# Simulate trajectory
	for i in range(times.size()):
		var dt = times[i] - (times[i-1] if i > 0 else 0)
		
		# Calculate control for this step
		var control = calculate_step_control(
			current_state, target_state, times[i], flight_time,
			trajectory_type, thrust, desired_orientation
		)
		
		# Apply physics
		current_state = propagate_physics(current_state, control, dt)
		
		# Store state and control
		trajectory.states.append(current_state.duplicate(true))
		trajectory.controls.append(control)
		trajectory.timestamps.append(times[i])
	
	return trajectory

func generate_arc_trajectory(
	start_state: Dictionary,
	target_state: Dictionary,
	flight_time: float,
	approach_side: int,
	arc_factor: float
) -> Trajectory:
	"""Generate trajectory that arcs to approach from the side"""
	
	var trajectory = Trajectory.new()
	var current_state = start_state.duplicate(true)
	var times = build_time_array(flight_time)
	
	for i in range(times.size()):
		var dt = times[i] - (times[i-1] if i > 0 else 0)
		var progress = times[i] / flight_time
		
		# Calculate desired heading based on flight phase
		var to_target = target_state.position - current_state.position
		var direct_angle = to_target.angle()
		var perpendicular = direct_angle + (PI/2 * approach_side)
		
		var desired_angle: float
		if progress < 0.5:
			# Arc phase - blend toward perpendicular
			desired_angle = lerp_angle(direct_angle, perpendicular, arc_factor * progress * 2)
		else:
			# Return phase - blend back to direct
			var return_progress = (progress - 0.5) * 2
			desired_angle = lerp_angle(perpendicular, direct_angle, return_progress)
		
		# Calculate control
		var rotation_error = angle_difference(current_state.orientation, desired_angle)
		var control = {
			"thrust": max_acceleration,
			"rotation_rate": clamp(rotation_error * 10, -max_rotation_rate, max_rotation_rate)
		}
		
		# Apply physics
		current_state = propagate_physics(current_state, control, dt)
		
		# Store
		trajectory.states.append(current_state.duplicate(true))
		trajectory.controls.append(control)
		trajectory.timestamps.append(times[i])
	
	return trajectory

func generate_fan_converge_trajectory(
	start_state: Dictionary,
	target_state: Dictionary,
	time_to_impact: float,
	assigned_angle: float,
	convergence_start: float
) -> Trajectory:
	"""Generate trajectory that fans out then converges"""
	
	var trajectory = Trajectory.new()
	var current_state = start_state.duplicate(true)
	var times = build_time_array(time_to_impact)
	
	# Calculate fan-out direction
	var to_target = target_state.position - current_state.position
	var center_angle = to_target.angle()
	var fan_angle = center_angle + assigned_angle
	
	for i in range(times.size()):
		var dt = times[i] - (times[i-1] if i > 0 else 0)
		var progress = times[i] / time_to_impact
		
		# Calculate desired heading based on phase
		var desired_angle: float
		if progress < convergence_start:
			# Fan phase - head toward assigned angle
			var fan_progress = progress / convergence_start
			desired_angle = lerp_angle(current_state.orientation, fan_angle, fan_progress)
		else:
			# Converge phase - turn toward target
			var converge_progress = (progress - convergence_start) / (1.0 - convergence_start)
			var current_to_target = (target_state.position - current_state.position).angle()
			desired_angle = lerp_angle(fan_angle, current_to_target, converge_progress)
		
		# Calculate control
		var rotation_error = angle_difference(current_state.orientation, desired_angle)
		var control = {
			"thrust": max_acceleration * (0.8 + 0.2 * progress),  # Ramp up thrust
			"rotation_rate": clamp(rotation_error * 10, -max_rotation_rate, max_rotation_rate)
		}
		
		# Apply physics
		current_state = propagate_physics(current_state, control, dt)
		
		# Store
		trajectory.states.append(current_state.duplicate(true))
		trajectory.controls.append(control)
		trajectory.timestamps.append(times[i])
	
	return trajectory

func calculate_step_control(
	current_state: Dictionary,
	target_state: Dictionary,
	current_time: float,
	total_time: float,
	trajectory_type: String,
	thrust: float,
	desired_orientation: float
) -> Dictionary:
	"""Calculate control for a single timestep"""
	
	var progress = current_time / total_time
	
	# Predict where target will be
	var predicted_target_pos = target_state.position + target_state.velocity * (total_time - current_time)
	var to_target = predicted_target_pos - current_state.position
	
	# Update desired orientation to track predicted position
	if progress > 0.1:  # After initial phase
		desired_orientation = to_target.angle()
	
	# Calculate rotation control
	var rotation_error = angle_difference(current_state.orientation, desired_orientation)
	var rotation_rate = clamp(rotation_error * 10, -max_rotation_rate, max_rotation_rate)
	
	# Adjust thrust based on alignment
	var alignment = abs(rotation_error)
	var thrust_factor = 1.0 - min(alignment / PI, 0.5)  # Reduce thrust when misaligned
	
	return {
		"thrust": thrust * thrust_factor,
		"rotation_rate": rotation_rate
	}

func propagate_physics(state: Dictionary, control: Dictionary, dt: float) -> Dictionary:
	"""Propagate state forward by dt using control inputs"""
	
	var new_state = state.duplicate(true)
	
	# Update orientation
	new_state.orientation += control.rotation_rate * dt
	new_state.orientation = wrapf(new_state.orientation, -PI, PI)
	new_state.angular_velocity = control.rotation_rate
	
	# Update velocity (thrust in direction of orientation)
	var thrust_direction = Vector2.from_angle(new_state.orientation)
	var acceleration = thrust_direction * control.thrust
	new_state.velocity += acceleration * dt
	
	# Limit to max speed
	if new_state.velocity.length() > max_speed:
		new_state.velocity = new_state.velocity.normalized() * max_speed
	
	# Update position
	new_state.position += new_state.velocity * dt
	
	return new_state

func evaluate_trajectory(
	trajectory: Trajectory,
	target_state: Dictionary,
	trajectory_type: String,
	type_params: Dictionary
) -> float:
	"""Evaluate trajectory cost"""
	
	if trajectory.states.is_empty():
		return INF
	
	var total_cost = 0.0
	
	# Terminal state cost (how close do we get to target)
	var final_state = trajectory.states[-1]
	var final_time = trajectory.timestamps[-1]
	var predicted_target = target_state.position + target_state.velocity * final_time
	var miss_distance = (final_state.position - predicted_target).length()
	total_cost += miss_distance * miss_distance * cost_weights.distance
	
	# Control effort cost
	var control_cost = 0.0
	for i in range(trajectory.controls.size() - 1):
		var control_change = {
			"thrust": abs(trajectory.controls[i+1].thrust - trajectory.controls[i].thrust),
			"rotation": abs(trajectory.controls[i+1].rotation_rate - trajectory.controls[i].rotation_rate)
		}
		control_cost += control_change.thrust * 0.001 + control_change.rotation * 0.1
	total_cost += control_cost * cost_weights.control
	
	# Alignment cost (orientation should match velocity)
	var alignment_cost = 0.0
	for i in range(trajectory.states.size()):
		var state = trajectory.states[i]
		if state.velocity.length() > 10.0:
			var velocity_angle = state.velocity.angle()
			var alignment_error = abs(angle_difference(state.orientation, velocity_angle))
			alignment_cost += alignment_error
	alignment_cost /= trajectory.states.size()
	total_cost += alignment_cost * cost_weights.alignment
	
	# Type-specific costs
	match trajectory_type:
		"multi_angle":
			total_cost += evaluate_multi_angle_cost(trajectory, type_params)
		"simultaneous":
			total_cost += evaluate_simultaneous_cost(trajectory, type_params)
	
	return total_cost

func evaluate_multi_angle_cost(trajectory: Trajectory, params: Dictionary) -> float:
	"""Evaluate multi-angle specific costs"""
	
	# We want the final approach to be perpendicular to direct line
	if trajectory.states.is_empty():
		return 0.0
	
	var final_velocity = trajectory.states[-1].velocity
	if final_velocity.length() < 10.0:
		return 100.0  # Penalty for no velocity
	
	# This is simplified - full implementation would coordinate with other torpedoes
	return 0.0

func evaluate_simultaneous_cost(trajectory: Trajectory, params: Dictionary) -> float:
	"""Evaluate simultaneous impact specific costs"""
	
	var target_time = params.get("impact_time", 10.0)
	var assigned_angle = params.get("impact_angle", 0.0)
	
	# Time accuracy cost
	var final_time = trajectory.timestamps[-1] if trajectory.timestamps.size() > 0 else 0
	var time_error = abs(final_time - target_time)
	
	# Approach angle cost
	var angle_cost = 0.0
	if trajectory.states.size() > 0:
		var final_velocity = trajectory.states[-1].velocity
		if final_velocity.length() > 10.0:
			var approach_angle = final_velocity.angle()
			angle_cost = abs(angle_difference(approach_angle, assigned_angle))
	
	return (time_error * 10.0 + angle_cost * 5.0) * cost_weights.type_specific

func shift_trajectory_forward(trajectory: Trajectory, dt: float) -> Trajectory:
	"""Shift trajectory forward in time for recycling"""
	
	var shifted = Trajectory.new()
	
	if trajectory.states.size() < 2:
		return shifted
	
	# Find the index corresponding to dt in the future
	var shift_index = 0
	for i in range(trajectory.timestamps.size()):
		if trajectory.timestamps[i] >= dt:
			shift_index = i
			break
	
	# Copy states starting from shift_index
	for i in range(shift_index, trajectory.states.size()):
		shifted.states.append(trajectory.states[i])
		shifted.timestamps.append(trajectory.timestamps[i] - dt)
		if i < trajectory.controls.size():
			shifted.controls.append(trajectory.controls[i])
	
	# Extrapolate to maintain horizon length
	if shifted.states.size() > 0:
		var last_state = shifted.states[-1]
		var last_control = shifted.controls[-1] if shifted.controls.size() > 0 else {"thrust": 0, "rotation_rate": 0}
		var last_time = shifted.timestamps[-1]
		
		# Add a few extrapolated states
		for i in range(5):
			var extra_dt = FAR_HORIZON_DT
			last_time += extra_dt
			last_state = propagate_physics(last_state, last_control, extra_dt)
			shifted.states.append(last_state.duplicate(true))
			shifted.controls.append(last_control.duplicate(true))
			shifted.timestamps.append(last_time)
	
	shifted.cost = trajectory.cost * 1.1  # Slightly penalize recycled trajectories
	
	return shifted

func build_time_array(total_time: float) -> Array:
	"""Build array of timestamps with sliding window resolution"""
	
	var times = []
	var current_time = 0.0
	
	# Near horizon with fine resolution
	while current_time < min(NEAR_HORIZON_TIME, total_time):
		times.append(current_time)
		current_time += NEAR_HORIZON_DT
	
	# Far horizon with coarse resolution
	while current_time < total_time:
		times.append(current_time)
		current_time += FAR_HORIZON_DT
	
	# Ensure we have the final time
	if times.size() == 0 or abs(times[-1] - total_time) > 0.01:
		times.append(total_time)
	
	return times

func calculate_intercept_time(
	shooter_pos: Vector2,
	shooter_vel: Vector2,
	target_pos: Vector2,
	target_vel: Vector2,
	bullet_speed: float
) -> float:
	"""Calculate time to intercept moving target"""
	
	# Relative position and velocity
	var rel_pos = target_pos - shooter_pos
	var rel_vel = target_vel - shooter_vel
	
	# Quadratic equation coefficients
	var a = rel_vel.dot(rel_vel) - bullet_speed * bullet_speed
	var b = 2.0 * rel_pos.dot(rel_vel)
	var c = rel_pos.dot(rel_pos)
	
	# Solve quadratic
	if abs(a) < 0.001:
		# Linear case
		if abs(b) > 0.001:
			return -c / b
		else:
			return rel_pos.length() / bullet_speed
	
	var discriminant = b * b - 4 * a * c
	if discriminant < 0:
		# No solution - return approximate time
		return rel_pos.length() / bullet_speed
	
	var sqrt_disc = sqrt(discriminant)
	var t1 = (-b + sqrt_disc) / (2 * a)
	var t2 = (-b - sqrt_disc) / (2 * a)
	
	# Return smallest positive time
	if t1 > 0 and t2 > 0:
		return min(t1, t2)
	elif t1 > 0:
		return t1
	elif t2 > 0:
		return t2
	else:
		return rel_pos.length() / bullet_speed

func angle_difference(from: float, to: float) -> float:
	"""Calculate shortest angle difference"""
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

func get_debug_points() -> PackedVector2Array:
	"""Get trajectory points for debug visualization"""
	var points = PackedVector2Array()
	
	for state in current_trajectory.states:
		points.append(state.position)
	
	return points
