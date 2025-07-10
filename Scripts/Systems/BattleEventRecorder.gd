# Scripts/Managers/BattleEventRecorder.gd - PURE OBSERVER
extends Node
class_name BattleEventRecorder

# Pure event recording
var battle_events: Array = []
var frame_counter: int = 0
var battle_start_time: float = 0.0
var battle_active: bool = false

# Entity snapshots for analysis
var entity_snapshots: Dictionary = {}  # entity_id -> last known data

func _ready():
	# Listen for events
	add_to_group("battle_observers")
	
	print("BattleEventRecorder initialized - Pure observer mode")

func _physics_process(_delta):
	frame_counter += 1
	
	# Periodic snapshot of battle state
	if frame_counter % 60 == 0 and battle_active:  # Every second
		record_battle_snapshot()

# Observer interface - called by entities
func on_entity_spawned(entity: Node2D, entity_type: String):
	if not battle_active:
		start_battle_recording()
	
	var entity_id = ""
	if "torpedo_id" in entity:
		entity_id = entity.torpedo_id
	elif "bullet_id" in entity:
		entity_id = entity.bullet_id
	elif "pdc_id" in entity:
		entity_id = entity.pdc_id
	elif "entity_id" in entity:
		entity_id = entity.entity_id
		
	var event = {
		"type": "entity_spawned",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"frame": frame_counter,
		"entity_type": entity_type,
		"entity_id": entity_id,
		"position": entity.global_position,
		"faction": entity.faction if "faction" in entity else "unknown"
	}
	
	# Special tracking for bullets
	if entity_type == "pdc_bullet" and "source_pdc_id" in entity:
		event["source_pdc"] = entity.source_pdc_id
		if "target_id" in entity:
			event["target_id"] = entity.target_id
	
	# Special tracking for torpedoes
	if entity_type == "torpedo" and "source_ship_id" in entity:
		event["source_ship"] = entity.source_ship_id
	
	battle_events.append(event)
	
	# Store snapshot
	entity_snapshots[entity_id] = {
		"type": entity_type,
		"faction": event.faction,
		"spawn_time": event.timestamp,
		"last_position": entity.global_position,
		"source_pdc": event.get("source_pdc", ""),
		"is_alive": true
	}

func on_entity_dying(entity: Node2D, reason: String):
	var entity_id = ""
	if "torpedo_id" in entity:
		entity_id = entity.torpedo_id
	elif "bullet_id" in entity:
		entity_id = entity.bullet_id
	elif "pdc_id" in entity:
		entity_id = entity.pdc_id
	elif "entity_id" in entity:
		entity_id = entity.entity_id
	
	var entity_type = "unknown"
	if entity.has_meta("entity_type"):
		entity_type = entity.get_meta("entity_type")
	
	var event = {
		"type": "entity_destroyed",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"frame": frame_counter,
		"entity_type": entity_type,
		"entity_id": entity_id,
		"reason": reason,
		"position": entity.global_position,
		"lifetime": 0.0
	}
	
	# Calculate lifetime if we have spawn data
	if entity_snapshots.has(entity_id):
		var snapshot = entity_snapshots[entity_id]
		event["lifetime"] = event.timestamp - snapshot.spawn_time
		snapshot.is_alive = false
	
	# Special handling for PDC kills
	if reason == "bullet_impact" and entity.has_meta("last_hit_by"):
		event["killed_by_pdc"] = entity.get_meta("last_hit_by")
	
	# Special handling for torpedo impacts
	if reason == "target_impact" and entity_id.begins_with("bullet_"):
		if entity.has_meta("hit_target"):
			event["hit_target"] = entity.get_meta("hit_target")
	
	battle_events.append(event)

func on_entity_moved(entity: Node2D, new_position: Vector2):
	# Only record for performance - every 10th call
	if Engine.get_physics_frames() % 10 != 0:
		return
		
	var entity_id = ""
	if "torpedo_id" in entity:
		entity_id = entity.torpedo_id
	elif "bullet_id" in entity:
		entity_id = entity.bullet_id
		
	if entity_snapshots.has(entity_id):
		entity_snapshots[entity_id].last_position = new_position

func on_intercept(bullet: Node2D, torpedo: Node2D, pdc_id: String):
	var event = {
		"type": "intercept",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"frame": frame_counter,
		"bullet_id": bullet.bullet_id if "bullet_id" in bullet else "",
		"torpedo_id": torpedo.torpedo_id if "torpedo_id" in torpedo else "",
		"pdc_id": pdc_id,
		"position": bullet.global_position,
		"distance_to_ship": 0.0
	}
	
	# Calculate distance to ship
	var pdc_nodes = get_tree().get_nodes_in_group("pdcs")
	for pdc in pdc_nodes:
		if pdc.pdc_id == pdc_id:
			var ship = pdc.get_parent()
			if ship:
				event["distance_to_ship"] = bullet.global_position.distance_to(ship.global_position) * WorldSettings.meters_per_pixel
			break
	
	battle_events.append(event)

func on_pdc_fired(pdc: Node2D, target: Node2D):
	var event = {
		"type": "pdc_fired",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"frame": frame_counter,
		"pdc_id": pdc.pdc_id,
		"target_id": "",
		"mount_position": pdc.mount_position
	}
	
	if target and "torpedo_id" in target:
		event["target_id"] = target.torpedo_id
	
	battle_events.append(event)

func record_battle_snapshot():
	# Count current entities
	var torpedo_count = 0
	var bullet_count = 0
	var active_pdcs = 0
	
	# Count torpedoes
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	for torpedo in torpedoes:
		if "is_alive" in torpedo and torpedo.is_alive:
			if "marked_for_death" in torpedo and not torpedo.marked_for_death:
				torpedo_count += 1
	
	# Count bullets
	var bullets = get_tree().get_nodes_in_group("bullets")
	for bullet in bullets:
		if "is_alive" in bullet and bullet.is_alive:
			if "marked_for_death" in bullet and not bullet.marked_for_death:
				bullet_count += 1
	
	# Count active PDCs
	var pdcs = get_tree().get_nodes_in_group("pdcs")
	for pdc in pdcs:
		if pdc.current_target and pdc.is_firing:
			active_pdcs += 1
	
	var snapshot = {
		"type": "snapshot",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"frame": frame_counter,
		"torpedo_count": torpedo_count,
		"bullet_count": bullet_count,
		"active_pdcs": active_pdcs
	}
	
	battle_events.append(snapshot)

func start_battle_recording():
	battle_active = true
	battle_start_time = Time.get_ticks_msec() / 1000.0
	battle_events.clear()
	entity_snapshots.clear()
	frame_counter = 0
	
	print("BattleEventRecorder: Battle recording started")

func stop_battle_recording():
	battle_active = false
	
	var event = {
		"type": "battle_ended",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"frame": frame_counter,
		"duration": (Time.get_ticks_msec() / 1000.0) - battle_start_time
	}
	battle_events.append(event)
	
	print("BattleEventRecorder: Battle recording stopped")

# Analysis interface
func get_battle_data() -> Dictionary:
	return {
		"events": battle_events.duplicate(),
		"entity_snapshots": entity_snapshots.duplicate(),
		"battle_duration": (Time.get_ticks_msec() / 1000.0) - battle_start_time if battle_active else 0.0
	}

func clear_battle_data():
	battle_events.clear()
	entity_snapshots.clear()
	frame_counter = 0
	battle_active = false

# Analysis helpers
func count_intercepts_by_pdc() -> Dictionary:
	var pdc_stats = {}
	
	# Count all bullets fired by each PDC
	for event in battle_events:
		if event.type == "entity_spawned" and event.entity_type == "pdc_bullet":
			var pdc_id = event.get("source_pdc", "")
			if pdc_id != "":
				if not pdc_stats.has(pdc_id):
					pdc_stats[pdc_id] = {"fired": 0, "hits": 0}
				pdc_stats[pdc_id].fired += 1
	
	# Count successful intercepts
	for event in battle_events:
		if event.type == "intercept":
			var pdc_id = event.pdc_id
			if pdc_stats.has(pdc_id):
				pdc_stats[pdc_id].hits += 1
	
	return pdc_stats
