# ==== SENSOR SYSTEM EXAMPLE ====
# Scripts/Systems/SensorSystem.gd - Example of how to use EntityManager for sensors

extends Node

var entity_manager: Node

func _ready():
	entity_manager = get_node("/root/EntityManager")

# Radar sweep - detect all entities within range
func radar_sweep(center: Vector2, range_meters: float, detecting_faction: int) -> Array:
	if not entity_manager:
		return []
	
	var range_pixels = range_meters / WorldSettings.meters_per_pixel
	
	# Get all entities in range
	var detected = entity_manager.get_entities_in_radius(
		center, 
		range_pixels,
		[2, 3],  # ENEMY_SHIP, NEUTRAL_SHIP
		[],      # Any faction
		[4, 5]   # Exclude DESTROYED, CLEANUP states
	)
	
