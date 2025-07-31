# Scripts/Systems/TorpedoControlLayer.gd
extends Node
class_name TorpedoControlLayer

var torpedo: StandardTorpedo

# Proportional Navigation parameters
@export var navigation_constant: float = 3.0  # N (typically 3-5)
@export var max_rotation_rate: float = 10.0   # rad/s
@export var alignment_tolerance: float = 0.1  # radians

# Control smoothing
var last_rotation_command: float = 0.0
var rotation_rate_filter: float = 0.1  # Low-pass filter constant

# Add this class variable at the top of TorpedoControlLayer
var last_logged_phase: String = ""

func configure(torpedo_ref: StandardTorpedo):
	torpedo = torpedo_ref

func update_control(guidance: TorpedoDataStructures.GuidanceState,
				   physics: TorpedoDataStructures.TorpedoPhysicsState) -> TorpedoDataStructures.ControlCommands:
	
	var commands = TorpedoDataStructures.ControlCommands.new()
	
	# Set thrust based on guidance
	commands.thrust_magnitude = guidance.thrust_level
	commands.control_mode = guidance.guidance_mode
	
	# No target = no control
	if guidance.guidance_mode == "coast":
		commands.rotation_rate = 0.0
		return commands
	
	# Proportional Navigation implementation
	var los_vector = guidance.intercept_point - physics.position
	var los_angle = los_vector.angle()
	
	# Calculate line-of-sight rate
	var los_rate = calculate_los_rate(physics, guidance)
	
	# PN guidance law: acceleration = N * closing_velocity * LOS_rate
	var closing_velocity = physics.velocity.dot(los_vector.normalized()) * WorldSettings.meters_per_pixel
	var commanded_accel = navigation_constant * abs(closing_velocity) * los_rate
	
	# Convert commanded acceleration to rotation rate
	var current_speed = physics.velocity.length() * WorldSettings.meters_per_pixel
	var rotation_rate_from_pn = 0.0
	
	if current_speed > 10.0:  # Only apply PN if we're moving
		rotation_rate_from_pn = commanded_accel / current_speed
		rotation_rate_from_pn = clamp(rotation_rate_from_pn, -max_rotation_rate, max_rotation_rate)
	
	# Calculate direct pointing error for initial alignment
	var desired_rotation = los_angle  # No PI/2 adjustment - sprite points right
	var rotation_error = angle_difference(physics.rotation, desired_rotation)
	
	# Blend between direct pointing and PN
	var direct_rotation_rate = rotation_error * 5.0
	direct_rotation_rate = clamp(direct_rotation_rate, -max_rotation_rate, max_rotation_rate)
	
	# Use more direct pointing early, transition to PN as we get up to speed
	var pn_weight = clamp(current_speed / 500.0, 0.0, 1.0)
	var rotation_command = lerp(direct_rotation_rate, rotation_rate_from_pn, pn_weight)
	
	# Smooth the rotation command
	rotation_command = lerp(last_rotation_command, rotation_command, rotation_rate_filter)
	last_rotation_command = rotation_command
	
	commands.rotation_rate = rotation_command
	commands.desired_rotation = desired_rotation
	
	# Calculate alignment quality
	var velocity_heading_error = 0.0
	if physics.velocity.length() > 10.0:
		var velocity_angle = physics.velocity.angle()
		velocity_heading_error = abs(angle_difference(physics.rotation, velocity_angle))
	
	commands.alignment_quality = 1.0 - clamp(velocity_heading_error / PI, 0.0, 1.0)
	
	if DebugConfig.should_log("mpc_tuning") and torpedo.flight_phase != last_logged_phase:
		last_logged_phase = torpedo.flight_phase
		print("[Control] PN guidance at phase %s:" % torpedo.flight_phase)
		print("  Rotation error: %.1f deg, Closing velocity: %.1f m/s" % [rad_to_deg(rotation_error), closing_velocity])
	
	return commands

func calculate_los_rate(physics: TorpedoDataStructures.TorpedoPhysicsState,
					   guidance: TorpedoDataStructures.GuidanceState) -> float:
	# Simplified LOS rate calculation
	var los_vector = guidance.intercept_point - physics.position
	
	# Relative velocity
	var torpedo_vel_pixels = physics.velocity
	var target_vel_pixels = guidance.target_velocity / WorldSettings.meters_per_pixel
	var relative_vel = target_vel_pixels - torpedo_vel_pixels
	
	# LOS rate = (relative velocity perpendicular to LOS) / range
	var range_pixels = los_vector.length()
	if range_pixels < 1.0:
		return 0.0
	
	var los_normal = los_vector.rotated(PI/2).normalized()
	var perpendicular_vel = relative_vel.dot(los_normal)
	
	return perpendicular_vel / range_pixels

func angle_difference(from: float, to: float) -> float:
	var diff = fmod(to - from + PI, TAU) - PI
	return diff
