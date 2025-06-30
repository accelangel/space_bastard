extends Area2D
class_name Torpedo

# Torpedo specifications
@export var max_acceleration: float = 1470.0    # 150 Gs in m/s²
@export var launch_kick_velocity: float = 50.0   # Initial sideways impulse m/s
@export var proximity_meters: float = 10.0       # Auto-detonate range

# Intercept guidance parameters
@export var navigation_constant: float = 3.0     # Proportional navigation gain
@export var direct_weight: float = 0.05          # Direct intercept influence (0.0 to 1.0)
@export var speed_threshold: float = 200.0       # m/s - speed threshold for guidance transitions

# Direct intercept PID parameters
@export var kp: float = 800.0        # Proportional gain
@export var ki: float = 50.0         # Integral gain
@export var kd: float = 150.0        # Derivative gain

# TARGET DATA SYSTEM - New approach
var target_data: TargetData          # Our target information
var target_id: String               # ID of our target
var use_uncertain_data: bool = true # Whether to use confidence-based positioning

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var launcher_ship: Node2D

# IMPORTANT: No default value! Must be set by launcher
var meters_per_pixel: float

# Intercept guidance state
var previous_los: Vector2 = Vector2.ZERO
var previous_los_rate: float = 0.0
var previous_error: Vector2 = Vector2.ZERO
var integral_error: Vector2 = Vector2.ZERO
var integral_decay: float = 0.95      # Prevents integral windup

# Debug tracking
var launch_time: float = 0.0
var total_distance_traveled: float = 0.0

func _ready():
	launch_time = Time.get_ticks_msec() / 1000.0
	print("TORPEDO _ready() called at time: ", launch_time)
	print("  Initial position: ", global_position)
	print("  Using meters_per_pixel: ", meters_per_pixel)
	
	if not target_data and target_id.is_empty():
		print("No target data or ID set - destroying torpedo")
		queue_free()
		return
	
	# If we have target_id but no target_data, try to get it from TargetManager
	if target_id and not target_data:
		target_data = TargetManager.get_target_data(target_id)
		if not target_data:
			print("Could not find target data for ID: ", target_id)
			queue_free()
			return
	
	if meters_per_pixel <= 0:
		print("ERROR: Invalid meters_per_pixel value: ", meters_per_pixel)
		meters_per_pixel = WorldSettings.meters_per_pixel  # Fallback
		print("  Using fallback from WorldSettings: ", meters_per_pixel)
	
	# Calculate initial direction toward target
	var target_pos = _get_target_position()
	var to_target = (target_pos - global_position).normalized()
	
	# Small perpendicular kick + forward velocity
	var perpendicular = Vector2(-to_target.y, to_target.x)
	# Fix the ternary operator compatibility issue
	var kick_direction = 1.0 if randf() > 0.5 else -1.0
	var side_kick = perpendicular * launch_kick_velocity * kick_direction
	var forward_kick = to_target * 100.0
	
	velocity_mps = side_kick + forward_kick
	previous_los = to_target
	
	print("  Applied launch kick: ", velocity_mps, " m/s")
	print("  Distance to target: ", global_position.distance_to(target_pos) * meters_per_pixel, " meters")
	print("  Target confidence: ", target_data.confidence if target_data else "N/A")

func _physics_process(delta):
	# Validate target data
	if not _validate_target():
		print("Target lost or invalid - destroying torpedo")
		queue_free()
		return
	
	# Get current target position (may include uncertainty)
	var target_pos = _get_target_position()
	
	# Check proximity for detonation
	var distance_to_target_pixels = global_position.distance_to(target_pos)
	var distance_to_target_meters = distance_to_target_pixels * meters_per_pixel
	
	if distance_to_target_meters < proximity_meters:
		_impact()
		return
	
	# Track total distance traveled
	var speed_mps = velocity_mps.length()
	total_distance_traveled += speed_mps * delta
	
	# Calculate intercept trajectory using target data
	var commanded_acceleration = calculate_intercept_guidance(delta)
	
	# Apply acceleration
	velocity_mps += commanded_acceleration * delta
	
	# Convert to pixel movement
	var velocity_pixels_per_second = velocity_mps / meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Orient torpedo to face movement direction
	if velocity_mps.length() > 10.0:
		rotation = velocity_mps.angle()
	
	# Debug output
	if Engine.get_process_frames() % 60 == 0:
		debug_output(distance_to_target_meters, distance_to_target_pixels)

# Validate that we still have a valid target
func _validate_target() -> bool:
	if not target_data:
		return false
	
	# Check if target data is still valid
	if not target_data.is_valid():
		print("Target data became invalid (age: ", target_data.data_age, "s, confidence: ", target_data.confidence, ")")
		return false
	
	return true

# Get target position, potentially with uncertainty
func _get_target_position() -> Vector2:
	if not target_data:
		return global_position  # Fallback to avoid crashes
	
	if use_uncertain_data:
		return target_data.get_uncertain_position()
	else:
		return target_data.predicted_position

# Get target velocity for prediction
func _get_target_velocity() -> Vector2:
	if not target_data:
		return Vector2.ZERO
	
	return target_data.velocity

func calculate_intercept_guidance(delta: float) -> Vector2:
	# Calculate proportional navigation component
	var pn_command = calculate_proportional_navigation(delta)
	
	# Calculate direct intercept component  
	var direct_command = calculate_direct_intercept(delta)
	
	# Calculate dynamic mixing based on flight conditions and target data quality
	var current_speed = velocity_mps.length()
	var distance_to_target = global_position.distance_to(_get_target_position()) * meters_per_pixel
	
	# Use more direct guidance when:
	# 1. Moving slowly (startup phase)
	# 2. Very close to target (terminal phase)
	# 3. Target data confidence is low (less reliable proportional navigation)
	
	var effective_direct_weight = direct_weight
	
	# Increase direct guidance when moving slowly
	if current_speed < speed_threshold * 0.5:
		effective_direct_weight = min(1.0, direct_weight + 0.4)
	
	# Increase direct guidance when very close
	if distance_to_target < 200.0:  # Within 200 meters
		effective_direct_weight = min(1.0, direct_weight + 0.3)
	
	# Increase direct guidance when target data confidence is low
	if target_data and target_data.confidence < 0.5:
		effective_direct_weight = min(1.0, direct_weight + 0.25)
	
	# Combine commands with dynamic weighting
	var pn_weight = 1.0 - effective_direct_weight
	var final_command = pn_command * pn_weight + direct_command * effective_direct_weight
	
	# Limit maximum acceleration
	if final_command.length() > max_acceleration:
		final_command = final_command.normalized() * max_acceleration
	
	return final_command

func calculate_proportional_navigation(delta: float) -> Vector2:
	var target_pos = _get_target_position()
	var target_vel = _get_target_velocity()
	
	# Calculate line of sight vector and range
	var los_vector = target_pos - global_position
	var range_to_target = los_vector.length()
	
	if range_to_target < 1.0:  # Avoid division by zero
		return Vector2.ZERO
	
	var los_unit = los_vector / range_to_target
	
	# Calculate line of sight rate (angular velocity of LOS)
	var los_rate = 0.0
	if previous_los.length() > 0.1:
		var los_change = los_unit - previous_los
		los_rate = los_change.length() / delta
	
	previous_los = los_unit
	
	# Calculate closing velocity
	var relative_velocity = target_vel - velocity_mps
	var closing_velocity = -relative_velocity.dot(los_unit)
	
	if closing_velocity <= 0:  # Not closing on target
		return Vector2.ZERO
	
	# Calculate lateral acceleration command
	var los_perpendicular = Vector2(-los_unit.y, los_unit.x)
	var lateral_command = navigation_constant * closing_velocity * los_rate
	
	return los_perpendicular * lateral_command

func calculate_direct_intercept(delta: float) -> Vector2:
	var target_pos = _get_target_position()
	var target_vel = _get_target_velocity()
	
	# Calculate intercept point
	var intercept_point = calculate_intercept_point(global_position, velocity_mps, target_pos, target_vel)
	
	# PID control toward intercept point
	var error = intercept_point - global_position
	var error_magnitude = error.length()
	
	if error_magnitude < 1.0:  # Close enough
		return Vector2.ZERO
	
	var error_unit = error / error_magnitude
	
	# PID calculations
	var proportional = error * kp
	
	# Integral with decay to prevent windup
	integral_error = integral_error * integral_decay + error * delta
	var integral = integral_error * ki
	
	# Derivative
	var derivative = (error - previous_error) / delta * kd
	previous_error = error
	
	var pid_command = proportional + integral + derivative
	
	# Limit the command
	if pid_command.length() > max_acceleration:
		pid_command = pid_command.normalized() * max_acceleration
	
	return pid_command

func calculate_intercept_point(shooter_pos: Vector2, shooter_vel: Vector2, target_pos: Vector2, target_vel: Vector2) -> Vector2:
	# Simple intercept calculation - assumes torpedo can reach any speed
	var relative_pos = target_pos - shooter_pos
	var relative_vel = target_vel - shooter_vel
	
	# If target isn't moving relative to us, aim directly at it
	if relative_vel.length() < 1.0:
		return target_pos
	
	# Calculate time to intercept (assuming we can instantly match any required velocity)
	var torpedo_max_speed = sqrt(2.0 * max_acceleration * relative_pos.length())  # Rough estimate
	
	if torpedo_max_speed < 1.0:
		return target_pos
	
	# Solve for intercept time
	var a = relative_vel.dot(relative_vel) - torpedo_max_speed * torpedo_max_speed
	var b = 2.0 * relative_pos.dot(relative_vel)
	var c = relative_pos.dot(relative_pos)
	
	var discriminant = b * b - 4.0 * a * c
	
	if discriminant < 0.0 or abs(a) < 0.01:
		# No intercept possible or target not moving much
		return target_pos
	
	var t1 = (-b + sqrt(discriminant)) / (2.0 * a)
	var t2 = (-b - sqrt(discriminant)) / (2.0 * a)
	
	var intercept_time = t1 if t1 > 0 else t2
	if intercept_time <= 0:
		return target_pos
	
	return target_pos + target_vel * intercept_time

func _impact():
	print("TORPEDO IMPACT!")
	print("  Flight time: ", (Time.get_ticks_msec() / 1000.0) - launch_time, " seconds")
	print("  Distance traveled: ", total_distance_traveled, " meters")
	
	# Add explosion effects here
	
	queue_free()

func debug_output(distance_meters: float, distance_pixels: float):
	print("=== TORPEDO STATUS ===")
	print("  Position: ", global_position)
	print("  Velocity: ", velocity_mps.length(), " m/s")
	print("  Distance to target: ", distance_meters, " meters (", distance_pixels, " pixels)")
	print("  Target confidence: ", target_data.confidence if target_data else "N/A")
	print("  Flight time: ", (Time.get_ticks_msec() / 1000.0) - launch_time, " seconds")
	print("=====================")

# Methods called by launcher
func set_target(target: Node2D):
	if target:
		target_id = target.name + "_" + str(target.get_instance_id())
		# Try to get or create target data
		if has_node("/root/TargetManager"):
			target_data = get_node("/root/TargetManager").register_target(target)
		else:
			# Fallback: create basic target data
			target_data = TargetData.new(target_id, target, target.global_position)

func set_launcher(ship: Node2D):
	launcher_ship = ship

func set_meters_per_pixel(value: float):
	meters_per_pixel = value
