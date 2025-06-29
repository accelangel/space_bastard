extends Node2D
class_name EnemyShip

# Movement parameters
@export var acceleration_gs: float = 10.0  # Acceleration in Gs
var acceleration_mps2: float  # Will be calculated from Gs
var velocity_mps: Vector2 = Vector2.ZERO
var meters_per_pixel: float = 0.25  # Should match your world scale

# Movement direction
var movement_direction: Vector2 = Vector2(0, 1)  # Downward (positive Y)

func _ready():
	# Get the world scale from WorldSettings if available
	var world_settings = get_node("/root/WorldSettings") if has_node("/root/WorldSettings") else null
	if world_settings and "meters_per_pixel" in world_settings:
		meters_per_pixel = world_settings.meters_per_pixel
		print("EnemyShip using world scale: ", meters_per_pixel, " m/px")
	else:
		print("EnemyShip using default scale: ", meters_per_pixel, " m/px")
	
	# Convert Gs to m/s² (1 G = 9.81 m/s²)
	acceleration_mps2 = acceleration_gs * 9.81
	
	print("=== ENEMY SHIP INITIALIZED ===")
	print("  Starting position: ", global_position)
	print("  Acceleration: ", acceleration_gs, " Gs (", acceleration_mps2, " m/s²)")
	print("  Movement direction: ", movement_direction)
	print("  Meters per pixel: ", meters_per_pixel)
	print("===============================")

func _physics_process(delta):
	# Apply constant acceleration in the movement direction
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	
	# Convert velocity from m/s to pixels/second for position update
	var velocity_pixels_per_second = velocity_mps / meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Debug output every 60 frames (about once per second at 60 FPS)
	if Engine.get_process_frames() % 60 == 0:
		print("=== ENEMY SHIP STATUS ===")
		print("  Position: ", global_position)
		print("  Velocity: ", velocity_mps.length(), " m/s (", velocity_pixels_per_second.length(), " px/s)")
		print("  Direction: ", rad_to_deg(velocity_mps.angle()), " degrees")
		print("========================")

# Optional: Method to change movement parameters during runtime
func set_movement_direction(new_direction: Vector2):
	movement_direction = new_direction.normalized()
	print("EnemyShip movement direction changed to: ", movement_direction)

func set_acceleration(gs: float):
	acceleration_gs = gs
	acceleration_mps2 = acceleration_gs * 9.81
	print("EnemyShip acceleration changed to: ", acceleration_gs, " Gs (", acceleration_mps2, " m/s²)")

# Method to get current velocity for torpedo testing
func get_velocity_mps() -> Vector2:
	return velocity_mps
