# Scripts/Systems/TorpedoFlightPlans.gd
class_name TorpedoFlightPlans
extends RefCounted

# Static class for calculating desired velocity vectors for different flight patterns
# Returns where the torpedo SHOULD be going, not how to get there

static func calculate_straight_intercept(
	current_pos: Vector2, 
	current_vel: Vector2, 
	target_pos: Vector2, 
	target_vel: Vector2,
	max_speed: float
) -> Vector2:
	"""
	Calculate velocity vector for straight-line intercept.
	Returns desired velocity pointing at intercept point.
	NO LATERAL COMPONENTS, NO THRUST CALCULATIONS.
	"""
	
	# Calculate relative position and velocity
	var relative_pos = target_pos - current_pos
	var relative_vel = target_vel - current_vel
	
	# If target not moving relative to us, aim directly at it
	if relative_vel.length() < 1.0:
		return relative_pos.normalized() * max_speed
	
	# Quadratic equation for intercept time
	var a = relative_vel.dot(relative_vel) - max_speed * max_speed
	var b = 2.0 * relative_pos.dot(relative_vel)
	var c = relative_pos.dot(relative_pos)
	
	var discriminant = b * b - 4.0 * a * c
	
	# No intercept solution - aim at predicted position
	if discriminant < 0.0 or abs(a) < 0.01:
		var time_estimate = relative_pos.length() / max_speed
		var predicted_pos = target_pos + target_vel * time_estimate
		return (predicted_pos - current_pos).normalized() * max_speed
	
	# Calculate intercept times
	var sqrt_discriminant = sqrt(discriminant)
	var t1 = (-b + sqrt_discriminant) / (2.0 * a)
	var t2 = (-b - sqrt_discriminant) / (2.0 * a)
	
	# Choose positive time that's soonest
	var intercept_time = 0.0
	if t1 > 0 and t2 > 0:
		intercept_time = min(t1, t2)
	elif t1 > 0:
		intercept_time = t1
	elif t2 > 0:
		intercept_time = t2
	else:
		# Both times negative - aim at predicted position
		var time_estimate = relative_pos.length() / max_speed
		var predicted_pos = target_pos + target_vel * time_estimate
		return (predicted_pos - current_pos).normalized() * max_speed
	
	# Calculate intercept point and desired velocity
	var intercept_point = target_pos + target_vel * intercept_time
	var to_intercept = intercept_point - current_pos
	
	return to_intercept.normalized() * max_speed

static func calculate_multi_angle_intercept(
	current_pos: Vector2,
	current_vel: Vector2, 
	target_pos: Vector2,
	target_vel: Vector2,
	max_speed: float,
	approach_side: int  # 1 for right, -1 for left
) -> Vector2:
	"""
	Calculate velocity for 45° impact angle approach.
	Creates arc trajectory by biasing intercept calculation.
	Torpedoes impact perpendicular to each other (90° apart).
	"""
	
	# Get basic intercept solution first
	var straight_intercept_vel = calculate_straight_intercept(
		current_pos, current_vel, target_pos, target_vel, max_speed
	)
	
	# Calculate distance to target
	var to_target = target_pos - current_pos
	var distance_to_target = to_target.length()
	
	# Phase transitions based on distance
	var arc_phase = 0.0
	if distance_to_target < 500.0 / WorldSettings.meters_per_pixel:
		arc_phase = 1.0  # Full direct approach
	elif distance_to_target < 1500.0 / WorldSettings.meters_per_pixel:
		# Smooth transition from arc to direct
		var transition_start = 500.0 / WorldSettings.meters_per_pixel
		var transition_end = 1500.0 / WorldSettings.meters_per_pixel
		arc_phase = (distance_to_target - transition_start) / (transition_end - transition_start)
		arc_phase = 1.0 - arc_phase  # Invert so 1.0 = direct
	else:
		arc_phase = 0.0  # Full arc
	
	# Create perpendicular bias for arc trajectory
	var straight_direction = straight_intercept_vel.normalized()
	var perpendicular = Vector2(-straight_direction.y, straight_direction.x) * approach_side
	
	# Bias strength decreases as we get closer (phase transitions to direct)
	var bias_strength = 0.4 * (1.0 - arc_phase)  # 40% bias at max distance
	
	# Blend straight intercept with perpendicular bias
	var desired_direction = (straight_direction + perpendicular * bias_strength).normalized()
	
	return desired_direction * max_speed

static func calculate_simultaneous_impact_intercept(
	current_pos: Vector2,
	current_vel: Vector2,
	target_pos: Vector2, 
	target_vel: Vector2,
	max_speed: float,
	impact_time: float,  # When to hit
	impact_angle: float  # Assigned angle within 160° arc
) -> Vector2:
	"""
	Calculate velocity to hit target at exact time and angle.
	Angles spread across 160° arc (80° each side).
	All torpedoes impact simultaneously.
	"""
	
	# Calculate where target will be at impact time
	var impact_position = target_pos + target_vel * impact_time
	
	# Calculate required trajectory to reach impact point
	var to_impact = impact_position - current_pos
	var distance_to_impact = to_impact.length()
	var time_remaining = impact_time
	
	# Can't reach in time - do best effort
	if time_remaining <= 0.0:
		return to_impact.normalized() * max_speed
	
	# Calculate required speed to cover distance in time
	var required_speed = distance_to_impact / time_remaining
	
	# Account for current velocity - we need to change our trajectory
	var velocity_change_needed = (to_impact / time_remaining) - current_vel
	var velocity_change_magnitude = velocity_change_needed.length()
	
	# Check if we can physically achieve this velocity change
	# Estimate based on acceleration capability over time
	var max_velocity_change = max_speed * 2.0  # Rough estimate of max delta-v
	
	if velocity_change_magnitude > max_velocity_change or required_speed > max_speed:
		# Can't achieve perfect intercept - calculate best effort
		var momentum_factor = current_vel.dot(to_impact.normalized())
		if momentum_factor > 0:
			# Moving in roughly the right direction - use full speed
			return to_impact.normalized() * max_speed
		else:
			# Fighting against momentum - need aggressive turn
			# Aim perpendicular to current velocity to turn faster
			var perpendicular = Vector2(-current_vel.y, current_vel.x).normalized()
			var turn_direction = perpendicular if perpendicular.dot(to_impact) > 0 else -perpendicular
			return turn_direction.lerp(to_impact.normalized(), 0.3) * max_speed
	
	# We can reach the target - now calculate approach angle
	# Impact angle is relative to target's position at impact
	var target_to_torpedo_at_impact = Vector2.from_angle(impact_angle)
	
	# The torpedo should arrive from this direction
	var desired_approach_direction = -target_to_torpedo_at_impact
	
	# Blend direct path with desired approach angle based on time/distance
	var direct_direction = to_impact.normalized()
	
	# More time and shorter distance = more freedom to take indirect path
	var path_flexibility = min(1.0, time_remaining / 5.0)  # Full flexibility at 5+ seconds
	
	# Also consider distance - very close targets need more direct approach
	var distance_factor = clamp(distance_to_impact / 1000.0, 0.0, 1.0)
	path_flexibility *= distance_factor
	
	var blended_direction = direct_direction.lerp(desired_approach_direction, path_flexibility * 0.7)
	blended_direction = blended_direction.normalized()
	
	# Scale velocity to arrive on time
	# Account for curved path by slightly increasing speed
	var path_curve_factor = 1.0 + (path_flexibility * 0.1)  # Up to 10% faster for curved paths
	var final_speed = min(required_speed * path_curve_factor, max_speed)
	
	return blended_direction * final_speed

# Helper function to calculate realistic intercept time accounting for physics constraints
static func calculate_realistic_intercept_time(
	current_pos: Vector2,
	current_vel: Vector2,
	target_pos: Vector2,
	target_vel: Vector2,
	max_speed: float,
	max_acceleration: float,
	max_rotation_rate: float
) -> float:
	"""
	Calculate realistic intercept time accounting for:
	- Current velocity (can't instantly change)
	- Rotation time (can't instantly point elsewhere)
	- Acceleration limits
	Returns achievable intercept time, not ideal time.
	"""
	
	# First get ideal intercept time (no constraints)
	var ideal_vel = calculate_straight_intercept(current_pos, current_vel, target_pos, target_vel, max_speed)
	var to_intercept = ideal_vel.normalized() * ideal_vel.length()
	
	# Calculate velocity change needed
	var velocity_change = to_intercept - current_vel
	var velocity_change_magnitude = velocity_change.length()
	
	# Time to change velocity (acceleration limit)
	var accel_time = velocity_change_magnitude / max_acceleration
	
	# Angle change needed
	var current_heading = current_vel.angle() if current_vel.length() > 0.1 else 0.0
	var desired_heading = to_intercept.angle()
	var angle_change = abs(_angle_difference(current_heading, desired_heading))
	
	# Time to rotate
	var rotation_time = angle_change / max_rotation_rate
	
	# Total maneuver time (rotation and acceleration can overlap partially)
	var maneuver_time = max(rotation_time, accel_time * 0.5)
	
	# Recalculate intercept accounting for maneuver time
	var adjusted_target_pos = target_pos + target_vel * maneuver_time
	var adjusted_distance = (adjusted_target_pos - current_pos).length()
	var travel_time = adjusted_distance / (max_speed * 0.8)  # 80% of max speed average
	
	return maneuver_time + travel_time

static func _angle_difference(from: float, to: float) -> float:
	"""Calculate shortest angle difference between two angles"""
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

# Debug visualization helper
static func get_trajectory_preview_points(
	start_pos: Vector2,
	flight_plan_type: String,
	flight_plan_data: Dictionary,
	target_pos: Vector2,
	target_vel: Vector2,
	max_speed: float,
	point_count: int = 20
) -> PackedVector2Array:
	"""
	Generate preview points for trajectory visualization.
	Useful for debugging flight paths.
	"""
	var points = PackedVector2Array()
	var current_pos = start_pos
	var current_vel = Vector2.ZERO
	var time_step = 0.5  # Preview every 0.5 seconds
	
	for i in range(point_count):
		points.append(current_pos)
		
		# Calculate desired velocity based on flight plan
		var desired_vel = Vector2.ZERO
		match flight_plan_type:
			"straight":
				desired_vel = calculate_straight_intercept(
					current_pos, current_vel, target_pos, target_vel, max_speed
				)
			"multi_angle":
				desired_vel = calculate_multi_angle_intercept(
					current_pos, current_vel, target_pos, target_vel, max_speed,
					flight_plan_data.get("approach_side", 1)
				)
			"simultaneous":
				var time_to_impact = flight_plan_data.get("impact_time", 10.0) - (i * time_step)
				desired_vel = calculate_simultaneous_impact_intercept(
					current_pos, current_vel, target_pos, target_vel, max_speed,
					time_to_impact, flight_plan_data.get("impact_angle", 0.0)
				)
		
		# Simple physics integration for preview
		current_vel = current_vel.lerp(desired_vel, 0.1)
		current_pos += current_vel * time_step
		target_pos += target_vel * time_step
	
	return points
