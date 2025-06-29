extends Area2D
class_name Torpedo

# Torpedo specifications
@export var max_acceleration: float = 1470.0    # 150 Gs in m/s²
@export var launch_kick_velocity: float = 50.0   # Initial sideways impulse m/s
@export var proximity_meters: float = 10.0       # Auto-detonate range
@export var navigation_constant: float = 2.5     # Reduced for smoother curves
@export var damping_constant: float = 1.2        # Derivative term for smoothing

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

# Previous line of sight for calculating rate
var previous_los: Vector2 = Vector2.ZERO
var previous_los_rate: float = 0.0  # For derivative term

# Debug tracking
var launch_time: float = 0.0
var total_distance_traveled: float = 0.0

func _ready():
	launch_time = Time.get_ticks_msec() / 1000.0
	print("TORPEDO _ready() called at time: ", launch_time)
	print("  Initial position: ", global_position)
	print("  Meters per pixel: ", meters_per_pixel)
	
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
	
	# Initialize line of sight
	previous_los = to_target
	
	print("  Applied launch kick: ", velocity_mps, " m/s")
	print("  Distance to target: ", global_position.distance_to(target.global_position) * meters_per_pixel, " meters")
	print("TORPEDO _ready() complete")

func _physics_process(delta):
	if not target or not is_instance_valid(target):
		print("Target lost - destroying torpedo")
		queue_free()
		return
	
	update_target_tracking(delta)
	
	# Check proximity for detonation - USING REAL METERS
	var distance_to_target_pixels = global_position.distance_to(target.global_position)
	var distance_to_target_meters = distance_to_target_pixels * meters_per_pixel
	
	if distance_to_target_meters < proximity_meters:
		_impact()
		return
	
	# Track total distance traveled for debugging
	var speed_mps = velocity_mps.length()
	total_distance_traveled += speed_mps * delta
	
	# Proportional Navigation - much simpler than PID
	var current_los = (target.global_position - global_position).normalized()
	
	# Calculate line of sight rate (how fast it's rotating)
	if previous_los != Vector2.ZERO:
		# Cross product gives us the rotation rate
		var cross_product = previous_los.x * current_los.y - previous_los.y * current_los.x
		# This is proportional to the angular velocity of line of sight
		var los_angular_rate = cross_product / delta if delta > 0 else 0.0
		
		# PD Controller: Add derivative term for smoother guidance
		var rate_change = (los_angular_rate - previous_los_rate) / delta if delta > 0 else 0.0
		var pd_correction = navigation_constant * los_angular_rate - damping_constant * rate_change
		
		# Lateral acceleration command (perpendicular to velocity)
		var velocity_normalized = velocity_mps.normalized()
		var lateral_direction = Vector2(-velocity_normalized.y, velocity_normalized.x)
		
		# PD navigation law: a = N * V * λ_dot - D * V * λ_ddot
		var commanded_lateral_accel = velocity_mps.length() * pd_correction
		
		# Apply lateral acceleration
		var lateral_acceleration = lateral_direction * commanded_lateral_accel
		
		# Add forward thrust to maintain speed
		var forward_thrust = velocity_normalized * max_acceleration * 0.3  # 30% forward thrust
		
		# Total acceleration
		var total_acceleration = lateral_acceleration + forward_thrust
		
		# Limit to maximum acceleration
		if total_acceleration.length() > max_acceleration:
			total_acceleration = total_acceleration.normalized() * max_acceleration
		
		# Update velocity
		velocity_mps += total_acceleration * delta
		
		# Store for next iteration
		previous_los_rate = los_angular_rate
	else:
		# First frame - just apply forward thrust toward target
		var thrust_direction = current_los
		velocity_mps += thrust_direction * max_acceleration * delta
	
	# CRITICAL FIX: Scale-aware position update
	# Convert m/s velocity to pixels/second based on world scale
	var velocity_pixels_per_second = velocity_mps / meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Orient torpedo sprite to face its actual movement direction
	if velocity_mps.length() > 10.0:  # Only if moving fast enough to have meaningful direction
		rotation = velocity_mps.angle()
	
	# Update line of sight for next frame
	previous_los = current_los
	
	# Debug output with scale information
	if Engine.get_process_frames() % 60 == 0:
		var current_time = Time.get_ticks_msec() / 1000.0
		var flight_time = current_time - launch_time
		
		print("=== TORPEDO DEBUG ===")
		print("  Flight time: ", flight_time, " seconds")
		print("  Position: ", global_position)
		print("  Velocity: ", velocity_mps.length(), " m/s (", velocity_pixels_per_second.length(), " px/s)")
		print("  Distance to target: ", distance_to_target_meters, " meters (", distance_to_target_pixels, " pixels)")
		print("  Total distance traveled: ", total_distance_traveled, " meters")
		print("  Meters per pixel: ", meters_per_pixel)
		print("  Target at: ", target.global_position)
		print("  LOS angle: ", rad_to_deg(current_los.angle()), " degrees")
		print("  Velocity angle: ", rad_to_deg(velocity_mps.angle()), " degrees")
		print("===================")

func update_target_tracking(delta):
	if not target:
		return
	
	tracking_timer += delta
	var current_target_pos = target.global_position
	
	if target_tracking_initialized and tracking_timer > 0:
		# Calculate target velocity in pixels/second first
		var target_vel_pixels_per_sec = (current_target_pos - target_last_known_pos) / tracking_timer
		# Convert to m/s using current world scale
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
	print("Torpedo scale set to: ", meters_per_pixel, " meters per pixel")

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

func _draw():
	pass  # All debug drawing removed
