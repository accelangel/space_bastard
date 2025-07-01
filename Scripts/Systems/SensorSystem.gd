# ==== SENSOR SYSTEM EXAMPLE ====
# Scripts/Systems/SensorSystem.gd - Example of how to use EntityManager for sensors
# NOTE: EntityManager should be set up as an Autoload in Project Settings

extends Node

# No need to get the node reference since EntityManager is now an autoload
# You can access it directly as EntityManager

# Radar sweep - detect all entities within range
func radar_sweep(center: Vector2, range_meters: float, _detecting_faction: int = 0) -> Array:
	var range_pixels = range_meters / WorldSettings.meters_per_pixel
	
	# Get all entities in range - EntityManager is now accessible as a singleton
	var _detected = EntityManager.get_entities_in_radius(
		center, 
		range_pixels,
		[EntityManager.EntityType.ENEMY_SHIP, EntityManager.EntityType.NEUTRAL_SHIP],
		[],      # Any faction
		[EntityManager.EntityState.DESTROYED, EntityManager.EntityState.CLEANUP]
	)
	
	return _detected

# Example: Find nearest enemy to a position
func find_nearest_enemy(center: Vector2, max_range_meters: float = 10000.0):
	var range_pixels = max_range_meters / WorldSettings.meters_per_pixel
	
	var nearest_enemy = EntityManager.get_closest_entity(
		center,
		range_pixels,
		[EntityManager.EntityType.ENEMY_SHIP],  # Only enemy ships
		[EntityManager.FactionType.ENEMY]       # Only enemy faction
	)
	
	return nearest_enemy

# Example: Get all entities in a sector (rectangular area)
func scan_sector(sector_rect: Rect2) -> Array:
	return EntityManager.get_entities_in_rect(
		sector_rect,
		[],  # All entity types
		[]   # All factions
	)
