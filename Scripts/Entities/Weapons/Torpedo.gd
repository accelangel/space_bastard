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

# Target tracking
var target: Node2D
var target_last_known_pos: Vector2
var target_last_known_velocity: Vector2 = Vector2.ZERO
var previous_target_pos: Vector2 = Vector2.ZERO
var target_tracking_initialized: bool = false
var tracking_timer: float = 0.0

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var launcher_ship: Node2D
var meters_per_pixel: float = 0.25

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
	
	if not target:
		print("No target set - destroying torpedo")
		queue_free()
		return
	
	# Calculate initial direction toward target
	var to_target = (target.global_position - global_position).normalized()
	
	# Small perpendicular kick + forward velocity
	var perpendicular = Vector2(-to_target.y, to_target.x)
	var side_kick = perpendicular * launch_kick_velocity * (1.0 if randf() > 0.5 else -1.0)
	var forward_kick = to_target * 100.0
	
	velocity_mps = side_kick + forward_kick
	previous_los = to_target
	
	print("  Applied launch kick: ", velocity_mps, " m/s")
	print("  Distance to target: ", global_position.distance_to(target.global_position) * meters_per_pixel, " meters")

func _physics_process(delta):
	if not target or not is_instance_valid(target):
		print("Target lost - destroying torpedo")
		queue_free()
		return
	
	update_target_tracking(delta)
	
	# Check proximity for detonation
	var distance_to_target_pixels = global_position.distance_to(target.global_position)
	var distance_to_target_meters = distance_to_target_pixels * meters_per_pixel
	
	if distance_to_target_meters < proximity_meters:
		_impact()
		return
	
	# Track total distance traveled
	var speed_mps = velocity_mps.length()
	total_distance_traveled += speed_mps * delta
	
	# Calculate intercept trajectory
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

func calculate_intercept_guidance(delta: float) -> Vector2:
	# Calculate proportional navigation component
	var pn_command = calculate_proportional_navigation(delta)
	
	# Calculate direct intercept component
	var direct_command = calculate_direct_intercept(delta)
	
	# Calculate dynamic mixing based on flight conditions
	var current_speed = velocity_mps.length()
	var distance_to_target = global_position.distance_to(target.global_position) * meters_per_pixel
	
	# Use more direct guidance when:
	# 1. Moving slowly (startup phase)
	# 2. Very close to target (terminal phase)
	
	var effective_direct_weight = direct_weight
	
	# Increase direct guidance when moving slowly
	if current_speed < speed_threshold * 0.5:
		effective_direct_weight = min(1.0, direct_weight + 0.4)
	
	# Increase direct guidance when very close
	if distance_to_target < 200.0:  # Within 200 meters
		effective_direct_weight = min(1.0, direct_weight + 0.3)
	
	# Blend the two approaches
	var pn_weight = 1.0 - effective_direct_weight
	var blended_command = pn_command * pn_weight + direct_command * effective_direct_weight
	
	# Ensure we don't exceed max acceleration
	if blended_command.length() > max_acceleration:
		blended_command = blended_command.normalized() * max_acceleration
	
	return blended_command

func calculate_proportional_navigation(delta: float) -> Vector2:
	var current_los = (target.global_position - global_position).normalized()
	
	if previous_los == Vector2.ZERO:
		previous_los = current_los
		return current_los * max_acceleration * 0.5
	
	# Calculate line of sight rate
	var cross_product = previous_los.x * current_los.y - previous_los.y * current_los.x
	var los_angular_rate = cross_product / delta if delta > 0 else 0.0
	
	# Proportional navigation command
	var velocity_normalized = velocity_mps.normalized()
	var lateral_direction = Vector2(-velocity_normalized.y, velocity_normalized.x)
	
	var commanded_lateral_accel = velocity_mps.length() * navigation_constant * los_angular_rate
	var lateral_acceleration = lateral_direction * commanded_lateral_accel
	
	# Add forward thrust
	var forward_thrust = velocity_normalized * max_acceleration * 0.3
	
	var total_acceleration = lateral_acceleration + forward_thrust
	
	# Limit acceleration
	if total_acceleration.length() > max_acceleration:
		total_acceleration = total_acceleration.normalized() * max_acceleration
	
	previous_los = current_los
	return total_acceleration

func calculate_direct_intercept(delta: float) -> Vector2:
	# Direct PID control toward target position
	var target_pos = target.global_position
	var current_pos = global_position
	
	# Error in pixel space, convert to meters
	var error_pixels = target_pos - current_pos
	var error_meters = error_pixels * meters_per_pixel
	
	# Direct intercept PID calculations
	integral_error = integral_error * integral_decay + error_meters * delta
	var derivative_error = (error_meters - previous_error) / delta if delta > 0 else Vector2.ZERO
	
	# PID output for direct intercept
	var direct_output = (kp * error_meters + 
						 ki * integral_error + 
						 kd * derivative_error)
	
	# Limit to maximum acceleration
	if direct_output.length() > max_acceleration:
		direct_output = direct_output.normalized() * max_acceleration
	
	previous_error = error_meters
	return direct_output

func update_target_tracking(delta):
	if not target:
		return
	
	tracking_timer += delta
	var current_target_pos = target.global_position
	
	if target_tracking_initialized and tracking_timer > 0:
		var target_vel_pixels_per_sec = (current_target_pos - target_last_known_pos) / tracking_timer
		target_last_known_velocity = target_vel_pixels_per_sec * meters_per_pixel
	else:
		target_last_known_velocity = Vector2.ZERO
		target_tracking_initialized = true
	
	previous_target_pos = target_last_known_pos
	target_last_known_pos = current_target_pos
	tracking_timer = 0.0

func set_target(new_target: Node2D):
	target = new_target
	if target:
		target_last_known_pos = target.global_position
		previous_target_pos = target.global_position
		target_last_known_velocity = Vector2.ZERO
		target_tracking_initialized = false
		tracking_timer = 0.0

func set_launcher(ship: Node2D):
	launcher_ship = ship

func set_meters_per_pixel(pixel_scale: float):
	meters_per_pixel = pixel_scale

func debug_output(distance_meters: float, _distance_pixels: float):
	var current_time = Time.get_ticks_msec() / 1000.0
	var flight_time = current_time - launch_time
	
	print("=== TORPEDO DEBUG ===")
	print("  Flight time: ", flight_time, " seconds")
	print("  Position: ", global_position)
	print("  Velocity: ", velocity_mps.length(), " m/s")
	print("  Distance to target: ", distance_meters, " meters")
	print("  Total distance traveled: ", total_distance_traveled, " meters")
	print("===================")

func _on_area_entered(area):
	if launcher_ship and (area == launcher_ship or area.get_parent() == launcher_ship):
		return
	_impact()

func _on_body_entered(body):
	if body == launcher_ship:
		return
	_impact()

func _impact():
	var current_time = Time.get_ticks_msec() / 1000.0
	var flight_time = current_time - launch_time
	print("=== TORPEDO IMPACT ===")
	print("  Flight time: ", flight_time, " seconds")
	print("  Total distance: ", total_distance_traveled, " meters")
	print("  Average speed: ", total_distance_traveled / flight_time if flight_time > 0.0 else 0.0, " m/s")
	print("======================")
	queue_free()
