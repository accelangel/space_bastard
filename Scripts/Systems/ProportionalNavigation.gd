# Scripts/Systems/ProportionalNavigation.gd
class_name ProportionalNavigation
extends Node

# Core parameters from TuningParams
var navigation_constant_N: float = 3.0
var velocity_gain: float = 0.001
var velocity_anticipation: float = 0.5
var rotation_thrust_penalty: float = 0.5
var thrust_smoothing: float = 0.5
var position_tolerance: float = 100.0
var velocity_tolerance: float = 500.0

# PN state
var last_los_angle: float = 0.0
var first_frame: bool = true
var last_thrust: float = 0.5
var thrust_ramp_start_time: float = 0.0

func _ready():
	# Load parameters from tuning singleton
	update_parameters_from_tuning()
	
	# Listen for parameter changes during tuning
	if TuningParams.has_signal("parameters_changed"):
		TuningParams.parameters_changed.connect(update_parameters_from_tuning)

func update_parameters_from_tuning():
	var params = TuningParams.get_layer2_parameters()
	navigation_constant_N = params.get("navigation_constant_N", navigation_constant_N)
	velocity_gain = params.get("velocity_gain", velocity_gain)
	velocity_anticipation = params.get("velocity_anticipation", velocity_anticipation)
	rotation_thrust_penalty = params.get("rotation_thrust_penalty", rotation_thrust_penalty)
	thrust_smoothing = params.get("thrust_smoothing", thrust_smoothing)
	position_tolerance = params.get("position_tolerance", position_tolerance)
	velocity_tolerance = params.get("velocity_tolerance", velocity_tolerance)

func calculate_guidance(torpedo_pos: Vector2, torpedo_vel: Vector2, 
					   torpedo_orientation: float, torpedo_max_acceleration: float,
					   torpedo_max_rotation: float,
					   current_waypoint: TorpedoBase.Waypoint,
					   next_waypoint: TorpedoBase.Waypoint = null) -> Dictionary:
	
	# Line of sight to current waypoint
	var los = current_waypoint.position - torpedo_pos
	var los_angle = los.angle()
	
	# First frame initialization
	if first_frame:
		last_los_angle = los_angle
		first_frame = false
		return {"turn_rate": 0.0, "thrust": 0.5}
	
	# Calculate LOS rate
	var los_rate = angle_difference(los_angle, last_los_angle) / get_physics_process_delta_time()
	last_los_angle = los_angle
	
	# Closing velocity
	var closing_velocity = -torpedo_vel.dot(los.normalized())
	
	# PN guidance law for position tracking
	var commanded_acceleration = navigation_constant_N * closing_velocity * los_rate
	var pn_turn_rate = commanded_acceleration / torpedo_vel.length() if torpedo_vel.length() > 0.1 else 0.0
	
	# Handle special maneuvers
	if current_waypoint.maneuver_type == "flip":
		# Flip maneuver - maximum rotation, no thrust
		return {
			"turn_rate": sign(angle_difference(torpedo_orientation + PI, torpedo_orientation)) * torpedo_max_rotation,
			"thrust": 0.0
		}
	
	# Velocity matching through thrust control
	var current_speed = torpedo_vel.length()
	var target_speed = current_waypoint.velocity_target
	var speed_error = target_speed - current_speed
	
	# Look ahead to next waypoint for anticipatory control
	if next_waypoint and velocity_anticipation > 0:
		var time_to_waypoint = los.length() / max(closing_velocity, 100.0)
		var next_speed = next_waypoint.velocity_target
		var speed_change_needed = next_speed - target_speed
		
		# Anticipate needed velocity changes
		if abs(speed_change_needed) > 1000.0 and time_to_waypoint < 5.0:
			var anticipation_factor = (1.0 - time_to_waypoint / 5.0) * velocity_anticipation
			target_speed = lerp(target_speed, next_speed, anticipation_factor)
			speed_error = target_speed - current_speed
	
	# Calculate thrust based on velocity error and maneuver type
	var thrust = calculate_thrust_for_velocity(
		speed_error, 
		current_waypoint.maneuver_type,
		current_waypoint.thrust_limit,
		torpedo_max_acceleration
	)
	
	# Apply rotation thrust penalty
	var rotation_factor = 1.0 - min(abs(pn_turn_rate) / torpedo_max_rotation, rotation_thrust_penalty)
	thrust *= rotation_factor
	
	# Apply thrust smoothing
	thrust = smooth_thrust_change(thrust)
	
	return {
		"turn_rate": clamp(pn_turn_rate, -torpedo_max_rotation, torpedo_max_rotation),
		"thrust": clamp(thrust, 0.2, 1.0)
	}

func calculate_thrust_for_velocity(speed_error: float, maneuver_type: String, 
								  thrust_limit: float, max_acceleration: float) -> float:
	var base_thrust = 0.5
	
	# Velocity control gain
	base_thrust += speed_error * velocity_gain
	
	# Maneuver-specific adjustments
	match maneuver_type:
		"boost":
			base_thrust = 1.0
		"burn":
			base_thrust = 0.9
		"curve":
			base_thrust = 0.7
		"terminal":
			base_thrust = 0.8
	
	# Apply thrust limit
	base_thrust *= thrust_limit
	
	return base_thrust

func smooth_thrust_change(target_thrust: float) -> float:
	var smoothed = lerp(last_thrust, target_thrust, 1.0 - thrust_smoothing)
	last_thrust = smoothed
	return smoothed

func angle_difference(from: float, to: float) -> float:
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff
