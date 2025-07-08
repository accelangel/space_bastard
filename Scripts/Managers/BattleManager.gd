# Scripts/Systems/BattleManager.gd - FIXED BATTLE END DETECTION
extends Node

# Battle state tracking
enum BattlePhase {
	PRE_BATTLE,
	ACTIVE,
	POST_BATTLE
}

var current_phase: BattlePhase = BattlePhase.PRE_BATTLE
var battle_start_time: float = 0.0
var battle_end_time: float = 0.0
var battle_duration: float = 0.0

# Battle end detection
var no_torpedoes_timer: float = 0.0
var battle_end_delay: float = 3.0  # Wait 3 seconds after no torpedoes to end battle

# System references
var entity_manager: Node
var torpedo_launchers: Array = []
var ships: Array = []

# Battle data
var battle_events: Array = []
var entity_registry: Dictionary = {}
var battle_analysis: Dictionary = {}

# Settings
@export var auto_start_battles: bool = true
@export var print_detailed_reports: bool = true
@export var debug_enabled: bool = false

func _ready():
	# Get EntityManager reference
	entity_manager = get_node_or_null("/root/EntityManager")
	if not entity_manager:
		print("ERROR: BattleManager cannot find EntityManager")
		return
	
	# Find all torpedo launchers and ships in the scene
	call_deferred("discover_battle_systems")
	
	print("BattleManager initialized - Battle orchestration ready")

func discover_battle_systems():
	# Find all torpedo launchers and ships in the scene
	torpedo_launchers.clear()
	ships.clear()
	
	# Find torpedo launchers using groups
	var launcher_nodes = get_tree().get_nodes_in_group("torpedo_launchers")
	
	for launcher in launcher_nodes:
		torpedo_launchers.append(launcher)
		if debug_enabled:
			print("Found torpedo launcher: %s" % launcher.get_parent().name)
	
	# Find ships
	var ship_groups = ["player_ships", "enemy_ships"]
	for group in ship_groups:
		var group_ships = get_tree().get_nodes_in_group(group)
		ships.append_array(group_ships)
	
	print("BattleManager discovered: %d torpedo launchers, %d ships" % [
		torpedo_launchers.size(), ships.size()
	])

func _process(delta):
	match current_phase:
		BattlePhase.PRE_BATTLE:
			check_for_battle_start()
		BattlePhase.ACTIVE:
			monitor_active_battle(delta)
		BattlePhase.POST_BATTLE:
			pass  # Battle finished, waiting for new battle

func check_for_battle_start():
	# Detect when battle should start
	if not auto_start_battles:
		return
	
	# Check if any torpedoes exist (first torpedo registered = battle start)
	var torpedo_count = get_current_torpedo_count()
	
	if torpedo_count > 0:
		start_battle()

func monitor_active_battle(delta):
	# Monitor ongoing battle for end conditions
	var torpedo_count = get_current_torpedo_count()
	
	if torpedo_count == 0:
		no_torpedoes_timer += delta
		if no_torpedoes_timer >= battle_end_delay:
			end_battle()
	else:
		no_torpedoes_timer = 0.0  # Reset timer if torpedoes exist

func get_current_torpedo_count() -> int:
	# FIXED: Get current number of torpedoes from EntityManager with proper validation
	if not entity_manager:
		return 0
	
	var torpedo_entities = entity_manager.get_entities_by_type("torpedo")
	
	# FIXED: Count only valid, non-destroyed torpedoes
	var valid_count = 0
	for entity_data in torpedo_entities:
		if is_instance_valid(entity_data.node_ref) and not entity_data.is_destroyed:
			valid_count += 1
	
	return valid_count

func start_battle():
	# Initialize battle state and notify all systems
	if current_phase == BattlePhase.ACTIVE:
		return  # Already in battle
	
	current_phase = BattlePhase.ACTIVE
	battle_start_time = Time.get_ticks_msec() / 1000.0
	no_torpedoes_timer = 0.0
	
	# Clear EntityManager battle data for fresh start
	if entity_manager:
		entity_manager.clear_battle_data()
	
	# Start torpedo launching on all launchers
	for launcher in torpedo_launchers:
		if launcher.has_method("start_battle_firing"):
			launcher.start_battle_firing()
	
	print("=== BATTLE STARTED ===")
	if debug_enabled:
		print("Battle start time: %.2f" % battle_start_time)
		print("Active torpedo launchers: %d" % torpedo_launchers.size())

func end_battle():
	# Finalize battle and trigger analysis
	if current_phase != BattlePhase.ACTIVE:
		return  # Not in battle
	
	current_phase = BattlePhase.POST_BATTLE
	battle_end_time = Time.get_ticks_msec() / 1000.0
	battle_duration = battle_end_time - battle_start_time
	
	# Stop all torpedo launching
	for launcher in torpedo_launchers:
		if launcher.has_method("stop_battle_firing"):
			launcher.stop_battle_firing()
	
	# FIXED: Emergency stop all PDCs and Fire Control systems
	emergency_stop_all_systems()
	
	print("=== BATTLE ENDED ===")
	
	# Get battle data from EntityManager and analyze
	if entity_manager:
		var battle_data = entity_manager.get_battle_data()
		battle_events = battle_data.events
		entity_registry = battle_data.entity_registry
		
		# Perform analysis
		analyze_battle_data()
		
		if print_detailed_reports:
			print_comprehensive_battle_report()
	
	# Reset for next battle
	call_deferred("reset_for_next_battle")

# FIXED: Comprehensive system shutdown
func emergency_stop_all_systems():
	"""Stop all combat systems across all ships"""
	for ship in ships:
		if not is_instance_valid(ship):
			continue
			
		# Stop Fire Control Manager
		var fire_control = ship.get_node_or_null("FireControlManager")
		if fire_control and fire_control.has_method("emergency_stop_all_pdcs"):
			fire_control.emergency_stop_all_pdcs()
		
		# Stop individual PDCs as backup
		for child in ship.get_children():
			if child.has_method("emergency_stop"):
				child.emergency_stop()

func analyze_battle_data():
	# Process EntityManager events into battle statistics
	battle_analysis.clear()
	
	# Basic battle info
	battle_analysis["duration"] = battle_duration
	battle_analysis["start_time"] = battle_start_time
	battle_analysis["end_time"] = battle_end_time
	
	# Initialize counters
	battle_analysis["torpedoes_fired"] = 0
	battle_analysis["torpedoes_intercepted"] = 0
	battle_analysis["torpedoes_hit_ships"] = 0
	battle_analysis["total_bullets_fired"] = 0
	battle_analysis["successful_hits"] = 0
	battle_analysis["intercept_rate"] = 0.0
	
	# PDC performance tracking
	var pdc_performance = {}
	battle_analysis["pdc_performance"] = pdc_performance
	
	# Analyze events
	analyze_entity_lifecycle()
	analyze_collision_outcomes()
	analyze_pdc_effectiveness()
	
	# Calculate final statistics
	calculate_summary_statistics()

func analyze_entity_lifecycle():
	# Track entity births and deaths
	var torpedoes_born = 0
	var bullets_born = 0
	
	for event in battle_events:
		if event.type == "entity_registered":
			match event.entity_type:
				"torpedo":
					torpedoes_born += 1
				"pdc_bullet":
					bullets_born += 1
	
	battle_analysis["torpedoes_fired"] = torpedoes_born
	battle_analysis["total_bullets_fired"] = bullets_born

func analyze_collision_outcomes():
	# Analyze collision events to determine torpedo fates
	var torpedo_fates = {}  # torpedo_id -> "intercepted" or "hit_ship"
	var collision_details = []
	
	# Track all collisions
	for event in battle_events:
		if event.type == "collision":
			var torpedo_id = ""
			var bullet_id = ""
			var is_torpedo_bullet_collision = false
			
			# Determine if this is torpedo vs bullet collision
			if event.entity1_type == "torpedo" and event.entity2_type == "pdc_bullet":
				torpedo_id = event.entity1_id
				bullet_id = event.entity2_id
				is_torpedo_bullet_collision = true
			elif event.entity1_type == "pdc_bullet" and event.entity2_type == "torpedo":
				torpedo_id = event.entity2_id
				bullet_id = event.entity1_id
				is_torpedo_bullet_collision = true
			
			if is_torpedo_bullet_collision:
				torpedo_fates[torpedo_id] = "intercepted"
				collision_details.append({
					"torpedo_id": torpedo_id,
					"bullet_id": bullet_id,
					"position": event.position,
					"timestamp": event.timestamp
				})
			
			# Check for torpedo-ship collisions
			if (event.entity1_type == "torpedo" and event.entity2_type in ["player_ship", "enemy_ship"]) or \
			   (event.entity2_type == "torpedo" and event.entity1_type in ["player_ship", "enemy_ship"]):
				torpedo_id = event.entity1_id if event.entity1_type == "torpedo" else event.entity2_id
				
				# Only mark as ship hit if not already intercepted
				if not torpedo_fates.has(torpedo_id):
					torpedo_fates[torpedo_id] = "hit_ship"
	
	# Count outcomes
	var intercepted_count = 0
	var ship_hit_count = 0
	
	for fate in torpedo_fates.values():
		if fate == "intercepted":
			intercepted_count += 1
		elif fate == "hit_ship":
			ship_hit_count += 1
	
	battle_analysis["torpedoes_intercepted"] = intercepted_count
	battle_analysis["torpedoes_hit_ships"] = ship_hit_count
	battle_analysis["collision_details"] = collision_details
	battle_analysis["torpedo_fates"] = torpedo_fates

func analyze_pdc_effectiveness():
	# Analyze PDC performance from bullet sources and collisions
	var pdc_stats = {}
	
	# Count bullets fired by each PDC
	for event in battle_events:
		if event.type == "entity_registered" and event.entity_type == "pdc_bullet":
			var pdc_id = event.source_pdc
			if pdc_id != "":
				if not pdc_stats.has(pdc_id):
					pdc_stats[pdc_id]["bullets_fired"] += 1
	
	# Count hits by matching collision events with bullet sources
	for event in battle_events:
		if event.type == "collision":
			var bullet_id = ""
			var is_successful_intercept = false
			
			# Find bullet in torpedo-bullet collisions
			if event.entity1_type == "pdc_bullet" and event.entity2_type == "torpedo":
				bullet_id = event.entity1_id
				is_successful_intercept = true
			elif event.entity2_type == "pdc_bullet" and event.entity1_type == "torpedo":
				bullet_id = event.entity2_id
				is_successful_intercept = true
			
			if is_successful_intercept:
				# Find which PDC fired this bullet
				for reg_event in battle_events:
					if reg_event.type == "entity_registered" and \
					   reg_event.entity_id == bullet_id and \
					   reg_event.entity_type == "pdc_bullet":
						var pdc_id = reg_event.source_pdc
						if pdc_id != "" and pdc_stats.has(pdc_id):
							pdc_stats[pdc_id]["hits"] += 1
						break
	
	# Calculate hit rates
	for pdc_id in pdc_stats:
		var stats = pdc_stats[pdc_id]
		if stats["bullets_fired"] > 0:
			stats["hit_rate"] = (float(stats["hits"]) / float(stats["bullets_fired"])) * 100.0
	
	battle_analysis["pdc_performance"] = pdc_stats

func calculate_summary_statistics():
	# Calculate high-level battle statistics
	var torpedoes_intercepted = battle_analysis["torpedoes_intercepted"]
	var torpedoes_hit_ships = battle_analysis["torpedoes_hit_ships"]
	
	# Calculate intercept rate
	var total_torpedoes_resolved = torpedoes_intercepted + torpedoes_hit_ships
	if total_torpedoes_resolved > 0:
		battle_analysis["intercept_rate"] = (float(torpedoes_intercepted) / float(total_torpedoes_resolved)) * 100.0
	
	# Calculate ammunition efficiency
	var total_bullets = battle_analysis["total_bullets_fired"]
	if total_bullets > 0 and torpedoes_intercepted > 0:
		battle_analysis["rounds_per_intercept"] = float(total_bullets) / float(torpedoes_intercepted)
	else:
		battle_analysis["rounds_per_intercept"] = 0.0

func print_comprehensive_battle_report():
	# Print detailed battle analysis to console
	print("\n" + "=".repeat(60))
	print("                 BATTLE REPORT")
	print("=".repeat(60))
	
	# Basic battle info
	print("Battle Duration: %.1f seconds" % battle_analysis["duration"])
	print("")
	
	# Core statistics
	print("ENGAGEMENT SUMMARY:")
	print("  Torpedoes Fired: %d" % battle_analysis["torpedoes_fired"])
	print("  Torpedoes Intercepted: %d" % battle_analysis["torpedoes_intercepted"])
	print("  Torpedoes Hit Ships: %d" % battle_analysis["torpedoes_hit_ships"])
	print("  Intercept Success Rate: %.1f%%" % battle_analysis["intercept_rate"])
	print("  Total Rounds Fired: %d" % battle_analysis["total_bullets_fired"])
	
	if battle_analysis["rounds_per_intercept"] > 0:
		print("  Rounds per Intercept: %.1f" % battle_analysis["rounds_per_intercept"])
	
	print("")
	
	# PDC Performance
	print("PDC PERFORMANCE:")
	var pdc_performance = battle_analysis["pdc_performance"]
	
	for pdc_id in pdc_performance:
		var stats = pdc_performance[pdc_id]
		
		print("  %s: %d rounds, %d hits (%.1f%% accuracy)" % [
			pdc_id.substr(4, 8), stats["bullets_fired"], stats["hits"], stats["hit_rate"]
		])
	
	print("")
	
	# Overall assessment
	print("TACTICAL ASSESSMENT:")
	if battle_analysis["torpedoes_hit_ships"] == 0:
		print("  PERFECT DEFENSE - All torpedoes intercepted!")
	elif battle_analysis["intercept_rate"] >= 90.0:
		print("  EXCELLENT DEFENSE - %.1f%% intercept rate" % battle_analysis["intercept_rate"])
	elif battle_analysis["intercept_rate"] >= 75.0:
		print("  GOOD DEFENSE - %.1f%% intercept rate" % battle_analysis["intercept_rate"])
	elif battle_analysis["intercept_rate"] >= 50.0:
		print("  MODERATE DEFENSE - %.1f%% intercept rate" % battle_analysis["intercept_rate"])
	else:
		print("  POOR DEFENSE - %.1f%% intercept rate" % battle_analysis["intercept_rate"])
	
	# Efficiency analysis
	if battle_analysis["rounds_per_intercept"] > 0:
		if battle_analysis["rounds_per_intercept"] > 50.0:
			print("  - High ammunition expenditure (%.1f rounds/kill)" % battle_analysis["rounds_per_intercept"])
		elif battle_analysis["rounds_per_intercept"] < 20.0:
			print("  - Good ammunition efficiency (%.1f rounds/kill)" % battle_analysis["rounds_per_intercept"])
		else:
			print("  - Moderate ammunition efficiency (%.1f rounds/kill)" % battle_analysis["rounds_per_intercept"])
	
	print("=".repeat(60))
	print("")

func reset_for_next_battle():
	# Reset state for next battle
	current_phase = BattlePhase.PRE_BATTLE
	no_torpedoes_timer = 0.0
	battle_events.clear()
	entity_registry.clear()
	battle_analysis.clear()
	
	if debug_enabled:
		print("BattleManager reset for next battle")

# Public interface
func manual_start_battle():
	# Manually start a battle (for testing)
	start_battle()

func manual_end_battle():
	# Manually end current battle
	if current_phase == BattlePhase.ACTIVE:
		end_battle()

func is_battle_active() -> bool:
	return current_phase == BattlePhase.ACTIVE

func get_battle_statistics() -> Dictionary:
	return battle_analysis.duplicate()

func set_auto_battle_detection(enabled: bool):
	auto_start_battles = enabledd] = {
						"bullets_fired": 0,
						"hits": 0,
						"hit_rate": 0.0
					}
				pdc_stats[pdc_i
