# Scripts/Systems/ShipManager.gd
extends Node

var ships: Dictionary = {}  # ship_id -> ship_node

func register_ship(ship: Node2D):  # Use Node2D instead of BaseShip for now
	if ship.has_method("get_ship_type"):  # Verify it's actually a ship
		var ship_id = ship.ship_id if "ship_id" in ship else ship.name
		ships[ship_id] = ship
		print("Ship registered: ", ship_id, " (", ship.get_ship_type(), ")")
	else:
		print("Warning: Tried to register non-ship node: ", ship.name)

func get_ship(ship_id: String) -> Node2D:  # Return Node2D for now
	return ships.get(ship_id)

func get_all_ships() -> Array:
	return ships.values()

func get_ships_by_type(ship_type: String) -> Array:
	var result = []
	for ship in ships.values():
		if ship.has_method("get_ship_type") and ship.get_ship_type() == ship_type:
			result.append(ship)
	return result

func _ready():
	print("ShipManager initialized")
