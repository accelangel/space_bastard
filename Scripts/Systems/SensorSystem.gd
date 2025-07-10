# Scripts/Systems/SensorSystem.gd - IMMEDIATE STATE VERSION
extends Node2D
class_name SensorSystem

# Parent ship info
var parent_ship: Node2D
var ship_faction: String = "friendly"

# DEBUG CONTROL
@export var debug_enabled: bool = false

func _ready():
	add_to_group("sensor_systems")
	parent_ship = get_parent()
	
	if parent_ship and "faction" in parent_ship:
		ship_faction = parent_ship.faction

# Called by entities to report their positions
func report_entity_position(_entity: Node2D, _position: Vector2, _entity_type: String, _faction: String):
	# We don't store anything - just used for immediate queries
	pass

# IMMEDIATE STATE QUERIES - check scene tree directly
func get_all_enemy_torpedoes() -> Array:
	var torpedoes = []
	var all_torpedoes = get_tree().get_nodes_in_group("torpedoes")
	
	for torpedo in all_torpedoes:
		if is_valid_enemy(torpedo):
			torpedoes.append(torpedo)
	
	return torpedoes

func get_all_enemy_ships() -> Array:
	var ships = []
	var enemy_group = "player_ships" if ship_faction == "hostile" else "enemy_ships"
	var enemy_ships = get_tree().get_nodes_in_group(enemy_group)
	
	for ship in enemy_ships:
		if is_valid_entity(ship):
			ships.append(ship)
	
	return ships

func get_closest_enemy_ship() -> Node2D:
	if not parent_ship:
		return null
		
	var closest_ship = null
	var closest_distance_sq = INF
	
	var enemy_ships = get_all_enemy_ships()
	for ship in enemy_ships:
		var distance_sq = parent_ship.global_position.distance_squared_to(ship.global_position)
		if distance_sq < closest_distance_sq:
			closest_ship = ship
			closest_distance_sq = distance_sq
	
	return closest_ship

func is_valid_enemy(entity: Node2D) -> bool:
	if not is_valid_entity(entity):
		return false
	
	# Check faction
	var entity_faction = entity.get("faction")
	if not entity_faction:
		return false
		
	return is_enemy_faction(entity_faction)

func is_valid_entity(entity: Node2D) -> bool:
	if not entity:
		return false
	if not is_instance_valid(entity):
		return false
	if not entity.is_inside_tree():
		return false
	if entity.get("marked_for_death"):
		return false
	return true

func is_enemy_faction(other_faction: String) -> bool:
	if ship_faction == "friendly":
		return other_faction == "hostile"
	elif ship_faction == "hostile":
		return other_faction == "friendly"
	return false

func get_debug_info() -> String:
	var torpedo_count = get_all_enemy_torpedoes().size()
	var ship_count = get_all_enemy_ships().size()
	return "Contacts: %d ships, %d torpedoes" % [ship_count, torpedo_count]
