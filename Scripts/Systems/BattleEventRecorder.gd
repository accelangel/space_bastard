# Scripts/Systems/BattleEventRecorder.gd - Frame-rate independent version
extends Node
class_name BattleEventRecorder

# Pure event recording
var battle_events: Array = []
var battle_start_time: float = 0.0
var battle_active: bool = false

# Timer-based snapshots (not frame-based)
var snapshot_timer: float = 0.0
var snapshot_interval: float = 1.0  # Snapshot every second

# Entity snapshots for analysis
var entity_snapshots: Dictionary = {}  # entity_id -> last known data

# Track entities spawned before battle officially started
var pre_battle_entities: Array = []

# Debug flag
@export var debug_enabled: bool = false

# Public method to check if recording is active
func is_recording_active() -> bool:
	return battle_active

func _ready():
	# Subscribe to mode changes
	GameMode.mode_changed.connect(_on_mode_changed)
	
	# Add to group immediately at start of _ready
	add_to_group("battle_observers")
	
	print("BattleEventRecorder initialized - Pure observer mode")
	
	# Look for any torpedoes that spawned before we were ready
	call_deferred("check_for_existing_torpedoes")

func _on_mode_changed(new_mode: GameMode.Mode):
	if new_mode != GameMode.Mode.BATTLE:
		# Stop any active recording
		if battle_active:
			stop_battle_recording()
		# Clear data when leaving battle mode
		clear_battle_data()

func check_for_existing_torpedoes():
	"""Check for any torpedoes that spawned before we were ready to observe them"""
	var existing_torpedoes = get_tree().get_nodes_in_group("torpedoes")
	
	if existing_torpedoes.size() > 0:
		print("DEBUG: check_for_existing_torpedoes() found %d torpedoes in scene" % existing_torpedoes.size())
		print("DEBUG: Current battle_events count: %d" % battle_events.size())
		
		# Process each torpedo as if we just received its spawn notification
		for torpedo in existing_torpedoes:
			if is_instance_valid(torpedo) and not torpedo.get("marked_for_death"):
				var torpedo_id = get_entity_id(torpedo)
				
				# Check if we already have this torpedo recorded
				var already_recorded = false
				for event in battle_events:
					if event.type == "entity_spawned" and event.entity_id == torpedo_id:
						already_recorded = true
						break
				
				# Also check pre-battle entities
				if not already_recorded:
					for event in pre_battle_entities:
						if event.type == "entity_spawned" and event.entity_id == torpedo_id:
							already_recorded = true
							break
				
				# Also check if already in entity snapshots
				if not already_recorded and entity_snapshots.has(torpedo_id):
					already_recorded = true
				
				# Only process if not already recorded
				if not already_recorded:
					if debug_enabled:
						print("BattleEventRecorder: Recording missed torpedo spawn: %s" % torpedo_id)
					on_entity_spawned(torpedo, "torpedo")

func _physics_process(delta):
	# Timer-based snapshots instead of frame counting
	snapshot_timer += delta
	
	# Periodic snapshot of battle state
	if snapshot_timer >= snapshot_interval and battle_active:
		snapshot_timer = 0.0
		record_battle_snapshot()

# Observer interface - called by entities
func on_entity_spawned(entity: Node2D, entity_type: String):
	# Only record during battle mode
	if not GameMode.is_battle_mode():
		return
	
	var entity_id = get_entity_id(entity)
	
	if debug_enabled:
		print("BattleRecorder: Entity spawned - %s (%s)" % [entity_id, entity_type])
		
	var event = {
		"type": "entity_spawned",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"entity_type": entity_type,
		"entity_id": entity_id,
		"position": entity.global_position,
		"faction": entity.get("faction") if "faction" in entity else "unknown"
	}
	
	# Special tracking for bullets
	if entity_type == "pdc_bullet" and "source_pdc_id" in entity:
		event["source_pdc"] = entity.source_pdc_id
		if "target_id" in entity:
			event["target_id"] = entity.target_id
	
	# Special tracking for torpedoes
	if entity_type == "torpedo" and "source_ship_id" in entity:
		event["source_ship"] = entity.source_ship_id
	
	# Don't auto-start on first torpedo if not in battle mode
	if not battle_active and entity_type == "torpedo":
		if not GameMode.is_battle_mode():
			return
	
	# If battle hasn't started yet, store in pre-battle array
	if not battle_active:
		pre_battle_entities.append(event)
		# Auto-start battle on first torpedo
		if entity_type == "torpedo":
			print("DEBUG: First torpedo %s triggered battle start" % entity_id)
			start_battle_recording()
			# Add all pre-battle entities to the main events array
			for pre_event in pre_battle_entities:
				battle_events.append(pre_event)
			pre_battle_entities.clear()
			print("DEBUG: Battle events after first torpedo: %d" % battle_events.size())
	else:
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
	# Only record during battle mode
	if not GameMode.is_battle_mode():
		return
	
	var entity_id = get_entity_id(entity)
	var entity_type = get_entity_type(entity)
	
	if debug_enabled:
		print("BattleRecorder: Entity dying - %s (%s) reason: %s" % [entity_id, entity_type, reason])
	
	var event = {
		"type": "entity_destroyed",
		"timestamp": Time.get_ticks_msec() / 1000.0,
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

func on_entity_moved(_entity: Node2D, _new_position: Vector2):
	# Timer-based sampling is better than frame-based
	# This function might be called too frequently, so we ignore it
	pass

func on_intercept(bullet: Node2D, torpedo: Node2D, pdc_id: String):
	if debug_enabled:
		print("BattleRecorder: Intercept! PDC %s hit torpedo %s" % [pdc_id, get_entity_id(torpedo)])
		
	var event = {
		"type": "intercept",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"bullet_id": bullet.get("bullet_id") if bullet.has("bullet_id") else "",
		"torpedo_id": torpedo.get("torpedo_id") if torpedo.has("torpedo_id") else "",
		"pdc_id": pdc_id,
		"position": bullet.global_position,
		"distance_to_ship": 0.0
	}
	
	# Calculate distance to ship
	var pdc_nodes = get_tree().get_nodes_in_group("pdcs")
	for pdc in pdc_nodes:
		if pdc.get("pdc_id") == pdc_id:
			var ship = pdc.get_parent()
			if ship:
				event["distance_to_ship"] = bullet.global_position.distance_to(ship.global_position) * WorldSettings.meters_per_pixel
			break
	
	battle_events.append(event)

func on_pdc_fired(pdc: Node2D, target: Node2D):
	if debug_enabled:
		var target_id = get_entity_id(target) if target else "none"
		print("BattleRecorder: PDC %s fired at %s" % [pdc.get("pdc_id"), target_id])
		
	var event = {
		"type": "pdc_fired",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"pdc_id": pdc.get("pdc_id"),
		"target_id": "",
		"mount_position": pdc.get("mount_position")
	}
	
	if target:
		event["target_id"] = get_entity_id(target)
	
	battle_events.append(event)

func record_battle_snapshot():
	# Count current entities
	var torpedo_count = 0
	var bullet_count = 0
	var active_pdcs = 0
	
	# Count torpedoes
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	for torpedo in torpedoes:
		if is_instance_valid(torpedo) and not torpedo.get("marked_for_death"):
			torpedo_count += 1
	
	# Count bullets
	var bullets = get_tree().get_nodes_in_group("bullets")
	for bullet in bullets:
		if is_instance_valid(bullet) and not bullet.get("marked_for_death"):
			bullet_count += 1
	
	# Count active PDCs
	var pdcs = get_tree().get_nodes_in_group("pdcs")
	for pdc in pdcs:
		if is_instance_valid(pdc) and pdc.get("current_target") and pdc.get("is_firing"):
			active_pdcs += 1
	
	var snapshot = {
		"type": "snapshot",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"torpedo_count": torpedo_count,
		"bullet_count": bullet_count,
		"active_pdcs": active_pdcs
	}
	
	if debug_enabled:
		print("BattleRecorder: Snapshot - Torpedoes: %d, Bullets: %d, Active PDCs: %d" % [
			torpedo_count, bullet_count, active_pdcs
		])
	
	battle_events.append(snapshot)

func start_battle_recording():
	# Make idempotent to prevent double-start issues
	if battle_active:
		print("DEBUG: start_battle_recording - already active, ignoring")
		return  # Already recording
		
	battle_active = true
	battle_start_time = Time.get_ticks_msec() / 1000.0
	snapshot_timer = 0.0
	
	print("BattleEventRecorder: Battle recording started")

func stop_battle_recording():
	battle_active = false
	
	var event = {
		"type": "battle_ended",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"duration": (Time.get_ticks_msec() / 1000.0) - battle_start_time
	}
	battle_events.append(event)
	
	print("BattleEventRecorder: Battle recording stopped")

# Helper functions
func get_entity_id(entity: Node2D) -> String:
	if "torpedo_id" in entity:
		return entity.torpedo_id
	elif "bullet_id" in entity:
		return entity.bullet_id
	elif "pdc_id" in entity:
		return entity.pdc_id
	elif "entity_id" in entity:
		return entity.entity_id
	else:
		return "unknown_%d" % entity.get_instance_id()

func get_entity_type(entity: Node2D) -> String:
	if entity.has_meta("entity_type"):
		return entity.get_meta("entity_type")
	elif entity.is_in_group("torpedoes"):
		return "torpedo"
	elif entity.is_in_group("bullets"):
		return "pdc_bullet"
	elif entity.is_in_group("pdcs"):
		return "pdc"
	elif entity.is_in_group("ships"):
		return "ship"
	else:
		return "unknown"

# Analysis interface
func get_battle_data() -> Dictionary:
	return {
		"events": battle_events.duplicate(),
		"entity_snapshots": entity_snapshots.duplicate(),
		"battle_duration": (Time.get_ticks_msec() / 1000.0) - battle_start_time if battle_active else 0.0
	}

func clear_battle_data():
	print("DEBUG: clear_battle_data called - clearing %d battle events" % battle_events.size())
	battle_events.clear()
	entity_snapshots.clear()
	pre_battle_entities.clear()
	snapshot_timer = 0.0
	battle_active = false

# Get accurate torpedo count from spawn events
func get_actual_torpedo_count() -> int:
	var torpedo_count = 0
	for event in battle_events:
		if event.type == "entity_spawned" and event.entity_type == "torpedo":
			torpedo_count += 1
	print("DEBUG: Found %d torpedo spawn events in battle_events" % torpedo_count)
	return torpedo_count

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
	
	# Track which torpedoes were hit to avoid double counting
	var torpedoes_hit_by_pdc = {}
	
	# Count successful intercepts - Avoid double counting
	for event in battle_events:
		if event.type == "intercept":
			var pdc_id = event.pdc_id
			var torpedo_id = event.get("torpedo_id", "")
			if pdc_stats.has(pdc_id) and not torpedoes_hit_by_pdc.has(torpedo_id):
				pdc_stats[pdc_id].hits += 1
				torpedoes_hit_by_pdc[torpedo_id] = pdc_id
		elif event.type == "entity_destroyed" and event.entity_type == "torpedo":
			# Only count if torpedo was destroyed by bullet impact AND not already counted
			if event.reason == "bullet_impact" and event.has("killed_by_pdc"):
				var pdc_id = event.killed_by_pdc
				var torpedo_id = event.entity_id
				if pdc_stats.has(pdc_id) and not torpedoes_hit_by_pdc.has(torpedo_id):
					pdc_stats[pdc_id].hits += 1
					torpedoes_hit_by_pdc[torpedo_id] = pdc_id
	
	return pdc_stats
