# Scripts/Entities/Ships/EnemyShip.gd
extends BaseShip  # Changed from Node2D to BaseShip
class_name EnemyShip

# EnemyShip-specific behavior
func _ready():
	# Call parent _ready() first
	super._ready()
	
	# Set enemy-specific movement
	movement_direction = Vector2(0, 1)  # Downward
	
	print("=== ENEMY SHIP INITIALIZED ===")
	print("  Starting position: ", global_position)
	print("  Acceleration: ", acceleration_gs, " Gs (", acceleration_mps2, " m/s²)")
	print("  Movement direction: ", movement_direction)
	print("  Meters per pixel: ", meters_per_pixel)
	print("  Ship ID: ", ship_id)
	print("===============================")

func _physics_process(delta):
	# Apply constant acceleration in the movement direction
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	
	# Convert velocity from m/s to pixels/second for position update
	var velocity_pixels_per_second = velocity_mps / meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Debug output every 60 frames
	if Engine.get_process_frames() % 60 == 0:
		print("=== ENEMY SHIP STATUS ===")
		print("  Position: ", global_position)
		print("  Velocity: ", velocity_mps.length(), " m/s")
		print("  Ship ID: ", ship_id)
		print("========================")

# Override the base class method
func get_ship_type() -> String:
	return "EnemyShip"
