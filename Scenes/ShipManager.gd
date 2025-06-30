# Managers/ShipManager.gd
extends Node

var ships: Dictionary = {}  # ship_id -> ship_node

func register_ship(ship: BaseShip):
	ships[ship.ship_id] = ship

func get_ship(ship_id: String) -> BaseShip:
	return ships.get(ship_id)
