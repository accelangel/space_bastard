# ==== UPDATED EnemyShip.gd Integration ====
# Add this to Scripts/Entities/Ships/EnemyShip.gd

extends BaseShip
class_name EnemyShip

func _ready():
	super._ready()
	movement_direction = Vector2(0, 1)
	
	# Legacy TargetManager registration (will be phased out)
	var target_manager = get_node_or_null("/root/TargetManager")
	if target_manager:
		target_manager.register_target(self)
		add_to_group("enemy_ships")

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
