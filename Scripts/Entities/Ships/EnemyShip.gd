# Scripts/Entities/Ships/EnemyShip.gd
extends Area2D
class_name EnemyShip

# Ship configuration
@export var ship_config: EnemyShipConfig
@export var faction: String = "hostile"

# Default values if no config provided
@export var default_acceleration_gs: float = 0.35
@export var default_max_speed_mps: float = 1000.0

# Movement
var acceleration_mps2: float
var velocity_mps: Vector2 = Vector2.ZERO
var movement_direction: Vector2 = Vector2(0, 1)

# Entity tracking
var entity_id: String

# Child nodes
@onready var sensor_system: SensorSystem = $SensorSystem
@onready var pdc_system: PDCSystem

func _ready():
	# Load config or use defaults
	if ship_config:
		acceleration_mps2 = ship_config.acceleration_gs * 9.81
	else:
		acceleration_mps2 = default_acceleration_gs * 9.81
	
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(self, "enemy_ship", faction)
		
	# Add PDC system programmatically
	pdc_system = PDCSystem.new()
	pdc_system.name = "PDCSystem"
	add_child(pdc_system)
	
	print("EnemyShip initialized with faction: ", faction)

func _physics_process(delta):
	# Simple movement
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	
	# Cap speed if config specifies
	if ship_config and velocity_mps.length() > ship_config.max_speed_mps:
		velocity_mps = velocity_mps.normalized() * ship_config.max_speed_mps
	
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Update EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity_position(entity_id, global_position)

func get_velocity_mps() -> Vector2:
	return velocity_mps

func set_movement_direction(new_direction: Vector2):
	movement_direction = new_direction.normalized()
