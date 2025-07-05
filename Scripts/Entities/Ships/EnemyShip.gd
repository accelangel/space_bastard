# ==== UPDATED EnemyShip.gd with SensorSystem ====
# Replace Scripts/Entities/Ships/EnemyShip.gd with this version

extends BaseShip
class_name EnemyShip

# Add sensor system as a child node
var sensor_system: SensorSystem = null

func _ready():
	super._ready()
	movement_direction = Vector2(0, 1)
	
	# Create and add sensor system
	setup_sensor_system()
	
	# Legacy TargetManager registration (will be phased out)
	var target_manager = get_node_or_null("/root/TargetManager")
	if target_manager:
		target_manager.register_target(self)
		add_to_group("enemy_ships")

func setup_sensor_system():
	# Create sensor system node
	sensor_system = preload("res://Scripts/Systems/SensorSystem.gd").new()
	sensor_system.name = "SensorSystem"
	
	# Configure for enemy ship
	sensor_system.radar_range_meters = 50000.0  # 3km detection range
	sensor_system.radar_update_interval = 0.3   # Fast updates for defense
	sensor_system.radar_accuracy = 1.0         # Good accuracy
	
	# Add as child
	add_child(sensor_system)
	
	print("EnemyShip: Added SensorSystem with range ", sensor_system.radar_range_meters, "m")

func _physics_process(delta):
	# Parent handles EntityManager updates
	super._physics_process(delta)
	
	# Ship movement logic
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	var velocity_pixels_per_second = velocity_mps / meters_per_pixel
	global_position += velocity_pixels_per_second * delta

func _get_entity_type() -> int:
	return 2  # EntityManager.EntityType.ENEMY_SHIP

func _get_faction_type() -> int:
	return 2  # EntityManager.FactionType.ENEMY

func get_ship_type() -> String:
	return "EnemyShip"

# Get sensor system reference for weapons
func get_sensor_system() -> SensorSystem:
	return sensor_system
