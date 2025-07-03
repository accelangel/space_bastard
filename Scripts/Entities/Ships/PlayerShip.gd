# ==== UPDATED PlayerShip.gd with Movement ====
# Replace Scripts/Entities/Ships/PlayerShip.gd with this version

extends BaseShip
class_name PlayerShip

@export var rotation_speed: float = 2.0

# Test movement variables
var test_acceleration: bool = true
var test_direction: Vector2 = Vector2(1, -1).normalized()  # Top-right diagonal
var test_gs: float = 1.0  # 2G acceleration

func _ready():
	super._ready()
	movement_direction = Vector2.ZERO
	
	# Set up the test acceleration
	if test_acceleration:
		set_acceleration(test_gs)
		set_movement_direction(test_direction)
		print("PlayerShip starting test acceleration at ", test_gs, "G in direction ", test_direction)

func _physics_process(delta):
	# Parent handles EntityManager updates
	super._physics_process(delta)
	
	# Ship movement logic (same as EnemyShip but with top-right direction)
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	var velocity_pixels_per_second = velocity_mps / meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Debug output every 60 frames (roughly once per second at 60fps)
	if Engine.get_process_frames() % 60 == 0:
		var speed_mps = velocity_mps.length()
		var speed_kmh = speed_mps * 3.6
		print("PlayerShip - Speed: %.1f m/s (%.1f km/h), Position: %s" % [speed_mps, speed_kmh, global_position])

func _get_entity_type() -> int:
	return 1  # EntityManager.EntityType.PLAYER_SHIP

func _get_faction_type() -> int:
	return 1  # EntityManager.FactionType.PLAYER

func get_ship_type() -> String:
	return "PlayerShip"

# Override the base velocity getter to return our current velocity
func get_velocity_mps() -> Vector2:
	return velocity_mps

# Method to start/stop the test acceleration
func toggle_test_acceleration():
	test_acceleration = !test_acceleration
	if test_acceleration:
		set_movement_direction(test_direction)
		print("Test acceleration enabled")
	else:
		set_movement_direction(Vector2.ZERO)
		print("Test acceleration disabled")

# Method to change test direction (for future use)
func set_test_direction(new_direction: Vector2):
	test_direction = new_direction.normalized()
	if test_acceleration:
		set_movement_direction(test_direction)
