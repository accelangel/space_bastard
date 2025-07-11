# Scripts/Managers/BattleManager.gd - FIXED BATTLE ANALYSIS
extends Node
class_name BattleManager

# Battle state tracking
enum BattlePhase {
	PRE_BATTLE,
	ACTIVE,
	POST_BATTLE
}

var current_phase: BattlePhase = BattlePhase.PRE_BATTLE
var battle_start_time: float = 0.0
var battle_end_time: float = 0.0

# Battle end detection
var no_torpedoes_timer: float = 0.0
var battle_end_delay: float = 3.0

# System references
var event_recorder: BattleEventRecorder
var torpedo_launchers: Array = []

# Settings
@export var auto_start_battles: bool = true
@export var print_detailed_reports: bool = true
@export var debug_enabled: bool = false

func _ready():
	# Add to group for easy finding
	add_to_group("battle_managers")
	
	# Find or create BattleEventRecorder
	var recorder_nodes = get_tree().get_nodes_in_group("battle_observers")
	for node in recorder_nodes:
		if node is BattleEventRecorder:
			event_recorder = node
			break
	
	if not event_recorder:
		print("WARNING: BattleManager cannot find BattleEventRecorder")
		# Don't create a new one, it should already exist in the scene
	
	# Discover battle systems
	call_deferred("discover_battle_systems")
	
	print("BattleManager initialized - Battle orchestration ready")

func discover_battle_systems():
	torpedo_launchers.clear()
	
	# Find all torpedo launchers in the scene
	var all_ships = get_tree().get_nodes_in_group("ships")
	
	for ship in all_ships:
		# Find torpedo launchers as children of ships
		for child in ship.get_children():
			if child is TorpedoLauncher:
				torpedo_launchers.append(child)
				if debug_enabled:
					print("Found torpedo launcher on: %s" % ship.name)
	
	print("BattleManager discovered: %d torpedo launchers" % torpedo_launchers.size())
	
	# Don't auto-start battles - wait for player input

func trigger_initial_battle():
	# This function is no longer needed - battles start when player fires torpedoes
	pass

func _process(delta):
	match current_phase:
		BattlePhase.PRE_BATTLE:
			check_for_battle_start()
		BattlePhase.ACTIVE:
			monitor_active_battle(delta)
		BattlePhase.POST_BATTLE:
			pass

func check_for_battle_start():
	# Check if any torpedoes exist
	var torpedo_count = get_current_torpedo_count()
	
	if torpedo_count > 0 and current_phase == BattlePhase.PRE_BATTLE:
		start_battle()

func get_current_torpedo_count() -> int:
	# Direct query of scene tree for immediate state
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	var valid_count = 0
	
	for torpedo in torpedoes:
		if is_instance_valid(torpedo) and not torpedo.get("marked_for_death"):
			valid_count += 1
	
	return valid_count

func get_active_pdc_count() -> int:
	var pdcs = get_tree().get_nodes_in_group("pdcs")
	var active_count = 0
	
	for pdc in pdcs:
		if pdc.current_target and pdc.is_firing:
			active_count += 1
	
	return active_count

func monitor_active_battle(delta):
	var torpedo_count = get_current_torpedo_count()
	var active_pdcs = get_active_pdc_count()
	
	# Battle ends when no torpedoes and no PDCs firing
	if torpedo_count == 0 and active_pdcs == 0:
		no_torpedoes_timer += delta
		
		if int(no_torpedoes_timer) != int(no_torpedoes_timer - delta):
			print("Battle ending: no torpedoes, no active PDCs (%.0fs)" % no_torpedoes_timer)
		
		if no_torpedoes_timer >= battle_end_delay:
			end_battle()
	else:
		no_torpedoes_timer = 0.0
	
	# Force end after 60 seconds
	var battle_runtime = Time.get_ticks_msec() / 1000.0 - battle_start_time
	if battle_runtime > 60.0:
		print("Force ending battle - runtime %.1f seconds" % battle_runtime)
		force_end_battle()

func start_battle():
	if current_phase == BattlePhase.ACTIVE:
		return
	
	current_phase = BattlePhase.ACTIVE
	battle_start_time = Time.get_ticks_msec() / 1000.0
	no_torpedoes_timer = 0.0
	
	# Clear event recorder data
	if event_recorder:
		event_recorder.clear_battle_data()
		event_recorder.start_battle_recording()
	
	print("=== BATTLE STARTED ===")
	print("Time: %.2f" % battle_start_time)

func end_battle():
	if current_phase != BattlePhase.ACTIVE:
		return
	
	current_phase = BattlePhase.POST_BATTLE
	battle_end_time = Time.get_ticks_msec() / 1000.0
	
	# Stop event recording
	if event_recorder:
		event_recorder.stop_battle_recording()
	
	# Emergency stop all combat systems
	emergency_stop_all_systems()
	
	print("=== BATTLE ENDED ===")
	print("Duration: %.1f seconds" % (battle_end_time - battle_start_time))
	
	# Analyze and report
	if event_recorder and print_detailed_reports:
		await get_tree().create_timer(0.1).timeout  # Small delay to ensure all events are recorded
		analyze_and_report_battle()
	
	# Reset for next battle
	call_deferred("reset_for_next_battle")

func force_end_battle():
	print("BATTLE: Force ending due to timeout")
	
	# Force stop all PDCs
	var pdcs = get_tree().get_nodes_in_group("pdcs")
	for pdc in pdcs:
		if pdc.has_method("emergency_stop"):
			pdc.emergency_stop()
	
	# Force stop all fire control systems
	var ships = get_tree().get_nodes_in_group("ships")
	for ship in ships:
		var fire_control = ship.get_node_or_null("FireControlManager")
		if fire_control and fire_control.has_method("emergency_stop_all"):
			fire_control.emergency_stop_all()
	
	if current_phase == BattlePhase.ACTIVE:
		end_battle()

func emergency_stop_all_systems():
	# Stop all PDCs
	var pdcs = get_tree().get_nodes_in_group("pdcs")
	for pdc in pdcs:
		if pdc.has_method("emergency_stop"):
			pdc.emergency_stop()
			print("PDC %s: EMERGENCY STOP" % pdc.pdc_id)
	
	# Stop all fire control managers
	var fire_controls = get_tree().get_nodes_in_group("fire_control_systems")
	for fc in fire_controls:
		if fc.has_method("emergency_stop_all"):
			fc.emergency_stop_all()

func analyze_and_report_battle():
	if not event_recorder:
		print("ERROR: No BattleEventRecorder available for analysis")
		return
	
	var battle_data = event_recorder.get_battle_data()
	var events = battle_data.events
	
	if debug_enabled:
		print("Battle data contains %d events" % events.size())
	
	print("\n" + "=".repeat(60))
	print("                 BATTLE REPORT")
	print("=".repeat(60))
	
	# Calculate actual duration
	var actual_duration = battle_end_time - battle_start_time
	print("Battle Duration: %.1f seconds" % actual_duration)
	print("")
	
	# Count entities
	var torpedoes_fired = 0
	var bullets_fired = 0
	var torpedoes_intercepted = 0
	var torpedoes_hit_ships = 0
	var pdc_fired_count = 0
	
	for event in events:
		if event.type == "entity_spawned":
			if event.entity_type == "torpedo":
				torpedoes_fired += 1
			elif event.entity_type == "pdc_bullet":
				bullets_fired += 1
		elif event.type == "pdc_fired":
			pdc_fired_count += 1
		elif event.type == "intercept":
			torpedoes_intercepted += 1
		elif event.type == "entity_destroyed":
			if event.entity_type == "torpedo":
				if event.reason == "bullet_impact":
					torpedoes_intercepted += 1
				elif event.reason == "target_impact":
					torpedoes_hit_ships += 1
	
	# If we didn't count bullets from spawns, estimate from PDC firing events
	if bullets_fired == 0 and pdc_fired_count > 0:
		# Estimate based on fire rate (18 rounds/second) and PDC firing events
		bullets_fired = pdc_fired_count
	
	print("ENGAGEMENT SUMMARY:")
	print("  Torpedoes Fired: %d" % torpedoes_fired)
	print("  Torpedoes Intercepted: %d" % torpedoes_intercepted)
	print("  Torpedoes Hit Ships: %d" % torpedoes_hit_ships)
	
	var intercept_rate = 0.0
	if torpedoes_fired > 0:
		intercept_rate = (float(torpedoes_intercepted) / float(torpedoes_fired)) * 100.0
	print("  Intercept Success Rate: %.1f%%" % intercept_rate)
	
	print("  Total Rounds Fired: %d" % bullets_fired)
	
	if torpedoes_intercepted > 0 and bullets_fired > 0:
		var rounds_per_kill = float(bullets_fired) / float(torpedoes_intercepted)
		print("  Rounds per Intercept: %.1f" % rounds_per_kill)
	
	# PDC performance
	print("\nPDC PERFORMANCE:")
	var pdc_stats = event_recorder.count_intercepts_by_pdc()
	
	if pdc_stats.size() == 0:
		print("  No PDC performance data available")
	else:
		for pdc_id in pdc_stats:
			var stats = pdc_stats[pdc_id]
			var accuracy = 0.0
			if stats.fired > 0:
				accuracy = (float(stats.hits) / float(stats.fired)) * 100.0
			print("  %s: %d rounds, %d hits (%.1f%% accuracy)" % [
				pdc_id, stats.fired, stats.hits, accuracy
			])
	
	print("\nTACTICAL ASSESSMENT:")
	if torpedoes_hit_ships == 0 and torpedoes_fired > 0:
		print("  PERFECT DEFENSE - All torpedoes intercepted!")
	elif intercept_rate >= 90.0:
		print("  EXCELLENT DEFENSE - %.1f%% intercept rate" % intercept_rate)
	elif intercept_rate >= 75.0:
		print("  GOOD DEFENSE - %.1f%% intercept rate" % intercept_rate)
	elif intercept_rate >= 50.0:
		print("  MODERATE DEFENSE - %.1f%% intercept rate" % intercept_rate)
	else:
		print("  POOR DEFENSE - %.1f%% intercept rate" % intercept_rate)
	
	print("=".repeat(60))
	print("")

func reset_for_next_battle():
	current_phase = BattlePhase.PRE_BATTLE
	no_torpedoes_timer = 0.0
	
	if debug_enabled:
		print("BattleManager reset for next battle")

# Public interface
func manual_start_battle():
	start_battle()

func manual_end_battle():
	if current_phase == BattlePhase.ACTIVE:
		end_battle()

func is_battle_active() -> bool:
	return current_phase == BattlePhase.ACTIVE
