# Scripts/Systems/SensorSystem.gd - CLEAN VERSION
extends Node2D
class_name SensorSystem

# NO RANGE LIMITS - radar sees entire map
var all_contacts: Array = []  # Array of entity data dictionaries
var parent_ship: Node2D
var ship_faction: String = "friendly"

func _ready():
	add_to_group("sensor_systems")
	parent_ship = get_parent()
	
	if parent_ship and "faction" in parent_ship:
		ship_faction = parent_ship.faction
	
	var ship_name: String = "unknown"
	if parent_ship:
		ship_name = parent_ship.name
	print("SensorSystem initialized for ", ship_name, " faction: ", ship_faction)

func update_contacts(entity_reports: Array):
	# Clear old contacts
	all_contacts.clear()
	
	# Filter for enemies only
	for report in entity_reports:
		if is_enemy_of(report.faction):
			all_contacts.append(report)

func is_enemy_of(other_faction: String) -> bool:
	# Simple faction logic
	if ship_faction == "friendly":
		return other_faction == "hostile"
	elif ship_faction == "hostile":
		return other_faction == "friendly"
	return false

func get_all_enemy_torpedoes() -> Array:
	var torpedoes = []
	for contact in all_contacts:
		if contact.type == "torpedo" and contact.node:
			torpedoes.append(contact.node)
	return torpedoes

func get_all_enemy_ships() -> Array:
	var ships = []
	for contact in all_contacts:
		if contact.type in ["player_ship", "enemy_ship"] and contact.node:
			ships.append(contact.node)
	return ships

func get_closest_enemy_ship() -> Node2D:
	if not parent_ship:
		return null
		
	var closest_ship = null
	var closest_distance_sq = INF
	
	for contact in all_contacts:
		if contact.type in ["player_ship", "enemy_ship"] and contact.node:
			var distance_sq = parent_ship.global_position.distance_squared_to(contact.position)
			if distance_sq < closest_distance_sq:
				closest_ship = contact.node
				closest_distance_sq = distance_sq
	
	return closest_ship

func get_debug_info() -> String:
	var torpedo_count = 0
	var ship_count = 0
	
	for contact in all_contacts:
		if contact.type == "torpedo":
			torpedo_count += 1
		elif contact.type in ["player_ship", "enemy_ship"]:
			ship_count += 1
	
	return "Contacts: %d ships, %d torpedoes" % [ship_count, torpedo_count]
