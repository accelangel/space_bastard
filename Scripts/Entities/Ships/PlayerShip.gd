# Scripts/Entities/Ships/PlayerShip.gd
extends Area2D
class_name PlayerShip

# Ship properties
@export var acceleration_gs: float = 0.05
@export var rotation_speed: float = 2.0
@export var faction: String = "friendly"

# Movement
var acceleration_mps2: float
var velocity_mps: Vector2 = Vector2.ZERO
var movement_direction: Vector2 = Vector2.ZERO

# Entity tracking
var entity_id: String

# Child nodes
@onready var sensor_system: SensorSystem = $SensorSystem
@onready var torpedo_launcher: TorpedoLauncher = $TorpedoLauncher

# Test movement (keep from original)
var test_acceleration: bool = true
var test_direction: Vector2 = Vector2(1, -1).normalized()
var test_gs: float = 1.0

func _ready():
	acceleration_mps2 = acceleration_gs * 9.81
	
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(self, "player_ship", faction)
	
	# Set up test acceleration
	if test_acceleration:
		set_acceleration(test_gs)
		set_movement_direction(test_direction)
		print("PlayerShip starting test acceleration at ", test_gs, "G")

func _physics_process(delta):
	# Update movement
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Update EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity_position(entity_id, global_position)
	
	# Debug output
	#if Engine.get_process_frames() % 60 == 0:
		#var speed_mps = velocity_mps.length()
		#var speed_kmh = speed_mps * 3.6
		#print("PlayerShip - Speed: %.1f m/s (%.1f km/h)" % [speed_mps, speed_kmh])

func set_movement_direction(new_direction: Vector2):
	movement_direction = new_direction.normalized()

func set_acceleration(gs: float):
	acceleration_gs = gs
	acceleration_mps2 = acceleration_gs * 9.81

func get_velocity_mps() -> Vector2:
	return velocity_mps

func toggle_test_acceleration():
	test_acceleration = !test_acceleration
	if test_acceleration:
		set_movement_direction(test_direction)
	else:
		set_movement_direction(Vector2.ZERO)
