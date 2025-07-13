# Scripts/Managers/BattleManager.gd - FIXED BATTLE SUMMARY WITH TUNING SUPPORT
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

# Settings
@export var auto_start_battles: bool = true
@export var print_detailed_reports: bool = true
@export var debug_enabled: bool = false

# Tuning support
var reports_enabled: bool = true

func _ready():
	# Add to group for easy finding
	add_to_group("battle_managers")
	
	# Use deferred call to find BattleEventRecorder after all nodes are ready
	call_deferred("find_battle_event_recorder")
	
	print("BattleManager initialized - Battle orchestration ready")

func find_battle_event_recorder():
	"""Find BattleEventRecorder after all nodes have called _ready()"""
	var recorder_nodes = get_tree().get_nodes_in_group("battle_observers")
	for node in recorder_nodes:
		if node is BattleEventRecorder:
			event_recorder = node
			if debug_enabled:
				print("BattleManager found BattleEventRecorder")
			break
	
	if not event_recorder:
		print("ERROR: BattleManager cannot find BattleEventRecorder - battle reports will not work")
	else:
		print("BattleManager connected to BattleEventRecorder")

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
	
	if reports_enabled:
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
	
	if reports_enabled:
		print("=== BATTLE ENDED ===")
		print("Duration: %.1f seconds" % (battle_end_time - battle_start_time))
	
	# FIXED: Always generate battle report if we have event recorder and reports enabled
	if event_recorder and reports_enabled:
		# Small delay to ensure all events are recorded
		await get_tree().create_timer(0.2).timeout
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
			if reports_enabled:
				print("PDC %s: EMERGENCY STOP" % pdc.pdc_id)
	
	# Stop all fire control managers
	var fire_controls = get_tree().get_nodes_in_group("fire_control_systems")
	for fc in fire_controls:
		if fc.has_method("emergency_stop_all"):
			fc.emergency_stop_all()

func analyze_and_report_battle():
	if not event_recorder or not reports_enabled:
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
	
	# Count entities - FIXED: Avoid double counting
	var torpedoes_fired = 0
	var bullets_fired = 0
	var torpedoes_intercepted = 0
	var torpedoes_hit_ships = 0
	
	# Track torpedo outcomes to avoid double counting
	var torpedo_outcomes = {}  # torpedo_id -> "intercepted" or "hit_ship"
	
	for event in events:
		if event.type == "entity_spawned":
			if event.entity_type == "torpedo":
				torpedoes_fired += 1
			elif event.entity_type == "pdc_bullet":
				bullets_fired += 1
		elif event.type == "intercept":
			# Mark torpedo as intercepted
			if event.has("torpedo_id"):
				torpedo_outcomes[event.torpedo_id] = "intercepted"
		elif event.type == "entity_destroyed":
			if event.entity_type == "torpedo":
				var torpedo_id = event.entity_id
				if event.reason == "bullet_impact" and not torpedo_outcomes.has(torpedo_id):
					torpedo_outcomes[torpedo_id] = "intercepted"
				elif event.reason == "ship_impact" and not torpedo_outcomes.has(torpedo_id):
					torpedo_outcomes[torpedo_id] = "hit_ship"
	
	# Count final outcomes
	for outcome in torpedo_outcomes.values():
		if outcome == "intercepted":
			torpedoes_intercepted += 1
		elif outcome == "hit_ship":
			torpedoes_hit_ships += 1
	
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
