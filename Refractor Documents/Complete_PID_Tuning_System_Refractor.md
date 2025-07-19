Complete PID Tuning System Fix - Implementation Plan
Problem Summary
Current Issues:

BattleManager and BattleEventRecorder automatically start when detecting torpedoes, regardless of game mode
FireControlManager continues running during PID tuning, assigning targets to "disabled" PDCs
PDCs don't properly respect the enabled flag - they accept targets even when disabled
PIDTuner gets stuck in TRACKING state because torpedoes don't report back (they hit but don't call the callback)
Ship positions aren't resetting between PID tuning cycles
Multiple systems fight for control - no clear separation between Battle Mode and PID Tuning Mode

Root Cause:
The game has no concept of "modes" - all systems run all the time and try to manage the same entities, creating chaos.
Solution: Mode-Aware Architecture with Immediate State
Phase 1: Create GameMode Singleton
Create Scripts/Systems/GameMode.gd:
gdscript# GameMode.gd - Autoload singleton
extends Node

enum Mode {
    NONE,           # No mode selected yet
    BATTLE,         # Normal battle mode
    PID_TUNING      # PID tuning mode
}

var current_mode: Mode = Mode.NONE
var mode_start_time: float = 0.0

signal mode_changed(new_mode: Mode)

func _ready():
    print("GameMode singleton initialized")

func set_mode(new_mode: Mode):
    if current_mode == new_mode:
        return
    
    var old_mode = current_mode
    
    # Clean up previous mode
    match current_mode:
        Mode.BATTLE:
            _cleanup_battle_mode()
        Mode.PID_TUNING:
            _cleanup_pid_tuning_mode()
    
    # Set new mode
    current_mode = new_mode
    mode_start_time = Time.get_ticks_msec() / 1000.0
    
    print("\n" + "=".repeat(50))
    print("GAME MODE CHANGED: %s -> %s" % [Mode.keys()[old_mode], Mode.keys()[new_mode]])
    print("=".repeat(50) + "\n")
    
    # Emit signal for all systems to reconfigure
    emit_signal("mode_changed", new_mode)

func is_battle_mode() -> bool:
    return current_mode == Mode.BATTLE

func is_pid_tuning_mode() -> bool:
    return current_mode == Mode.PID_TUNING

func get_mode_name() -> String:
    return Mode.keys()[current_mode]

func _cleanup_battle_mode():
    # Force end any active battle
    var battle_managers = get_tree().get_nodes_in_group("battle_managers")
    for bm in battle_managers:
        if bm.has_method("force_end_battle"):
            bm.force_end_battle()
    
    # Clean up all combat entities
    _cleanup_all_combat_entities()

func _cleanup_pid_tuning_mode():
    # Stop any active tuning
    if TunerSystem and TunerSystem.has_method("emergency_stop"):
        TunerSystem.emergency_stop()
    
    # Clean up all combat entities
    _cleanup_all_combat_entities()

func _cleanup_all_combat_entities():
    # Remove all torpedoes
    for torpedo in get_tree().get_nodes_in_group("torpedoes"):
        if is_instance_valid(torpedo):
            torpedo.queue_free()
    
    # Remove all bullets
    for bullet in get_tree().get_nodes_in_group("bullets"):
        if is_instance_valid(bullet):
            bullet.queue_free()
    
    print("Cleaned up all combat entities")
Add to Project Settings > Autoload:

Name: GameMode
Path: res://Scripts/Systems/GameMode.gd
Order: Before other autoloads

Phase 2: Update Battle Systems to be Mode-Aware
Update BattleManager.gd:
gdscriptfunc _ready():
    # Subscribe to mode changes
    GameMode.mode_changed.connect(_on_mode_changed)
    
    # Start with processing disabled
    set_process(false)
    
    # existing ready code...

func _on_mode_changed(new_mode: GameMode.Mode):
    var should_process = (new_mode == GameMode.Mode.BATTLE)
    set_process(should_process)
    
    if not should_process:
        # Reset to clean state
        current_phase = BattlePhase.PRE_BATTLE
        no_torpedoes_timer = 0.0
        print("BattleManager disabled - not in Battle Mode")
    else:
        print("BattleManager enabled - Battle Mode active")

func check_for_battle_start():
    # CRITICAL: Don't start battles outside of battle mode
    if not GameMode.is_battle_mode():
        return
    
    # existing battle start logic...
Update BattleEventRecorder.gd:
gdscriptfunc _ready():
    # Subscribe to mode changes
    GameMode.mode_changed.connect(_on_mode_changed)
    
    # existing ready code...

func _on_mode_changed(new_mode: GameMode.Mode):
    if new_mode != GameMode.Mode.BATTLE:
        # Stop any active recording
        if battle_active:
            stop_battle_recording()
        # Clear data
        clear_battle_data()

func on_entity_spawned(entity: Node2D, entity_type: String):
    # Only record during battle mode
    if not GameMode.is_battle_mode():
        return
    
    # Don't auto-start on first torpedo if not in battle mode
    if not battle_active and entity_type == "torpedo":
        if not GameMode.is_battle_mode():
            return
    
    # existing spawn logic...
Update FireControlManager.gd:
gdscriptfunc _ready():
    # Subscribe to mode changes
    GameMode.mode_changed.connect(_on_mode_changed)
    
    # Start with physics disabled
    set_physics_process(false)
    
    # existing ready code...

func _on_mode_changed(new_mode: GameMode.Mode):
    var should_process = (new_mode == GameMode.Mode.BATTLE)
    set_physics_process(should_process)
    
    if not should_process:
        # Emergency stop all PDCs
        emergency_stop_all()
        print("FireControlManager disabled on %s" % parent_ship.name)
    else:
        print("FireControlManager enabled on %s" % parent_ship.name)

func _physics_process(delta):
    # Extra safety check
    if not GameMode.is_battle_mode():
        set_physics_process(false)
        return
    
    # existing physics process...
Update PDCSystem.gd:
gdscriptfunc _ready():
    # Subscribe to mode changes
    GameMode.mode_changed.connect(_on_mode_changed)
    
    # existing ready code...
    
    # Set initial state based on current mode
    _configure_for_mode(GameMode.current_mode)

func _on_mode_changed(new_mode: GameMode.Mode):
    _configure_for_mode(new_mode)

func _configure_for_mode(mode: GameMode.Mode):
    match mode:
        GameMode.Mode.BATTLE:
            enabled = true
            print("PDC %s: Enabled for Battle Mode" % pdc_id)
        GameMode.Mode.PID_TUNING:
            enabled = false
            emergency_stop()
            print("PDC %s: Disabled for PID Tuning Mode" % pdc_id)
        _:
            enabled = false

func set_target(new_target: Node2D):
    # CRITICAL: Check enabled flag FIRST
    if not enabled:
        return
    
    # existing set_target logic...

func _physics_process(delta):
    # CRITICAL: Check both enabled flag AND game mode
    if not enabled or not GameMode.is_battle_mode():
        if is_firing:
            stop_firing()
        if current_target:
            current_target = null
        return
    
    # existing physics process...
Phase 3: Create PID Tuning Observer System
Create Scripts/Systems/PIDTuningObserver.gd:
gdscript# PIDTuningObserver.gd - Observes combat events during PID tuning
extends Node
class_name PIDTuningObserver

# Cycle tracking
var current_cycle_events: Array = []
var cycle_start_time: float = 0.0
var torpedoes_fired: int = 0
var torpedoes_hit: int = 0
var torpedoes_missed: int = 0
var miss_reasons: Dictionary = {}

signal cycle_complete(results: Dictionary)

func _ready():
    add_to_group("battle_observers")
    GameMode.mode_changed.connect(_on_mode_changed)
    set_process(false)

func _on_mode_changed(new_mode: GameMode.Mode):
    set_process(new_mode == GameMode.Mode.PID_TUNING)
    if new_mode == GameMode.Mode.PID_TUNING:
        reset_cycle_data()

func reset_cycle_data():
    current_cycle_events.clear()
    cycle_start_time = Time.get_ticks_msec() / 1000.0
    torpedoes_fired = 0
    torpedoes_hit = 0
    torpedoes_missed = 0
    miss_reasons.clear()

func on_entity_spawned(entity: Node2D, entity_type: String):
    if not GameMode.is_pid_tuning_mode():
        return
    
    if entity_type == "torpedo":
        torpedoes_fired += 1
        var event = {
            "type": "torpedo_fired",
            "torpedo_id": entity.get("torpedo_id"),
            "timestamp": Time.get_ticks_msec() / 1000.0
        }
        current_cycle_events.append(event)

func on_entity_dying(entity: Node2D, reason: String):
    if not GameMode.is_pid_tuning_mode():
        return
    
    if entity.is_in_group("torpedoes"):
        var event = {
            "type": "torpedo_destroyed",
            "torpedo_id": entity.get("torpedo_id"),
            "reason": reason,
            "timestamp": Time.get_ticks_msec() / 1000.0,
            "position": entity.global_position
        }
        
        # Track hits vs misses
        if reason == "ship_impact":
            torpedoes_hit += 1
        else:
            torpedoes_missed += 1
            if not miss_reasons.has(reason):
                miss_reasons[reason] = 0
            miss_reasons[reason] += 1
            
            # Get closest approach distance if available
            if entity.has("closest_approach_distance"):
                event["closest_approach"] = entity.closest_approach_distance
        
        current_cycle_events.append(event)

func get_cycle_results() -> Dictionary:
    return {
        "total_fired": torpedoes_fired,
        "hits": torpedoes_hit,
        "misses": torpedoes_missed,
        "hit_rate": float(torpedoes_hit) / float(torpedoes_fired) if torpedoes_fired > 0 else 0.0,
        "miss_reasons": miss_reasons,
        "cycle_duration": (Time.get_ticks_msec() / 1000.0) - cycle_start_time,
        "events": current_cycle_events
    }
Phase 4: Refactor PIDTuner to Use Immediate State
Update PIDTuner.gd:
gdscript# Simplified state machine
enum TuningState {
    IDLE,
    WAITING_BETWEEN_CYCLES,
    PREPARING_CYCLE,
    TORPEDOES_ACTIVE,
    ANALYZING_RESULTS
}

var tuning_state: TuningState = TuningState.IDLE
var state_timer: float = 0.0
var pid_observer: PIDTuningObserver

func _ready():
    set_process(false)
    
    # Subscribe to mode changes
    GameMode.mode_changed.connect(_on_mode_changed)
    
    # Create observer
    pid_observer = PIDTuningObserver.new()
    pid_observer.name = "PIDTuningObserver"
    add_child(pid_observer)
    
    print("PIDTuner singleton ready")

func _on_mode_changed(new_mode: GameMode.Mode):
    if new_mode == GameMode.Mode.PID_TUNING:
        start_tuning()
    else:
        stop_tuning()

func start_tuning():
    if tuning_active:
        return
    
    print("\n" + "=".repeat(40))
    print("    PID AUTO-TUNING ACTIVE")
    print("    Phase 1/3: STRAIGHT TRAJECTORY")
    print("    Press SPACE to stop")
    print("=".repeat(40))
    
    tuning_active = true
    tuning_state = TuningState.WAITING_BETWEEN_CYCLES
    current_phase = TuningPhase.TUNING_STRAIGHT
    current_cycle = 0
    consecutive_perfect_cycles = 0
    tuning_start_time = Time.get_ticks_msec() / 1000.0
    state_timer = 0.0
    
    # Find game objects
    find_game_objects()
    
    # Start processing
    set_process(true)

func _process(delta):
    if not tuning_active:
        return
    
    state_timer += delta
    
    match tuning_state:
        TuningState.WAITING_BETWEEN_CYCLES:
            if state_timer >= next_cycle_delay:
                prepare_new_cycle()
        
        TuningState.PREPARING_CYCLE:
            # Give physics a moment to settle
            if state_timer >= 0.5:
                fire_torpedo_volley()
                tuning_state = TuningState.TORPEDOES_ACTIVE
                state_timer = 0.0
        
        TuningState.TORPEDOES_ACTIVE:
            # Use immediate state query instead of tracking
            var active_torpedo_count = 0
            var torpedoes = get_tree().get_nodes_in_group("torpedoes")
            
            for torpedo in torpedoes:
                if is_instance_valid(torpedo) and not torpedo.get("marked_for_death"):
                    active_torpedo_count += 1
            
            # All torpedoes resolved
            if active_torpedo_count == 0 and state_timer > 1.0:  # Min 1 second
                analyze_cycle_results()
        
        TuningState.ANALYZING_RESULTS:
            # Analysis complete, wait for next cycle
            tuning_state = TuningState.WAITING_BETWEEN_CYCLES
            state_timer = 0.0

func prepare_new_cycle():
    current_cycle += 1
    cycle_start_time = Time.get_ticks_msec() / 1000.0
    
    # Get current trajectory type
    var trajectory_name = get_current_trajectory_name()
    
    print("\nCycle %d | Gains: Kp=%.3f, Ki=%.3f, Kd=%.3f" % [
        current_cycle,
        current_gains[trajectory_name].kp,
        current_gains[trajectory_name].ki,
        current_gains[trajectory_name].kd
    ])
    
    print("Resetting positions... Firing volley...")
    
    # Reset observer
    pid_observer.reset_cycle_data()
    
    # Clean field and reset positions
    cleanup_field()
    reset_battle_positions()
    
    tuning_state = TuningState.PREPARING_CYCLE
    state_timer = 0.0

func analyze_cycle_results():
    # Get results from observer
    var results = pid_observer.get_cycle_results()
    
    var result_str = "Result: %d/%d hits" % [results.hits, results.total_fired]
    
    # Check if perfect volley
    if results.hits == 8 and results.misses == 0:
        consecutive_perfect_cycles += 1
        result_str += " | Consecutive: %d/%d" % [consecutive_perfect_cycles, REQUIRED_PERFECT_CYCLES]
        print(result_str)
        
        # Check if phase complete
        if consecutive_perfect_cycles >= REQUIRED_PERFECT_CYCLES:
            complete_current_phase()
            return
    else:
        # Reset consecutive count
        consecutive_perfect_cycles = 0
        result_str += " | IMPERFECT - Resetting count"
        
        # Show miss reasons
        if results.misses > 0:
            for reason in results.miss_reasons:
                result_str += "\n  %s: %d" % [reason, results.miss_reasons[reason]]
        
        print(result_str)
        
        # Apply gradient descent
        apply_gradient_descent(results)
    
    print("Next cycle in %.0fs..." % next_cycle_delay)
    
    tuning_state = TuningState.ANALYZING_RESULTS
    state_timer = 0.0

func reset_battle_positions():
    # Force reset ship positions
    if player_ship:
        player_ship.set_deferred("global_position", PLAYER_START_POS)
        player_ship.set_deferred("rotation", PLAYER_START_ROT)
        if player_ship.has_method("force_reset_physics"):
            player_ship.call_deferred("force_reset_physics")
    
    if enemy_ship:
        enemy_ship.set_deferred("global_position", ENEMY_START_POS)
        enemy_ship.set_deferred("rotation", ENEMY_START_ROT)
        if enemy_ship.has_method("force_reset_physics"):
            enemy_ship.call_deferred("force_reset_physics")
    
    # Reset torpedo tubes
    if torpedo_launcher and torpedo_launcher.has_method("reset_all_tubes"):
        torpedo_launcher.reset_all_tubes()
Phase 5: Update Ship Reset Functions
Add to both PlayerShip.gd and EnemyShip.gd:
gdscriptfunc force_reset_physics():
    """Force physics state reset for PID tuning"""
    velocity_mps = Vector2.ZERO
    movement_direction = test_direction
    
    # Force physics server to update position
    if has_method("_integrate_forces"):
        PhysicsServer2D.body_set_state(
            get_rid(),
            PhysicsServer2D.BODY_STATE_TRANSFORM,
            Transform2D(rotation, global_position)
        )
    
    # Re-enable test acceleration
    if movement_enabled and test_acceleration:
        set_acceleration(test_gs)
Phase 6: Update ModeSelector
Update ModeSelector.gd:
gdscriptfunc start_battle_mode():
    if mode_selected:
        return
    
    mode_selected = true
    
    # Set game mode - this will configure all systems
    GameMode.set_mode(GameMode.Mode.BATTLE)
    
    fade_ui()
    
    # Enable ship movement
    enable_all_ship_movement()
    
    # Start battle timer in player ship
    var player_ships = get_tree().get_nodes_in_group("player_ships")
    if player_ships.size() > 0:
        var player = player_ships[0]
        if player.has_method("start_battle_timer"):
            player.start_battle_timer()

func start_pid_tuning():
    if mode_selected:
        return
    
    mode_selected = true
    
    # Set game mode - this will configure all systems
    GameMode.set_mode(GameMode.Mode.PID_TUNING)
    
    fade_ui()
    
    # Enable ship movement
    enable_all_ship_movement()
    
    # PIDTuner will start automatically from mode signal

func enable_all_ship_movement():
    var ships = get_tree().get_nodes_in_group("ships")
    for ship in ships:
        if ship.has_method("enable_movement"):
            ship.enable_movement()
Phase 7: Testing Safeguards
Add debug overlay (optional):
gdscript# DebugOverlay.gd
extends Control

var mode_label: Label

func _ready():
    mode_label = Label.new()
    mode_label.position = Vector2(10, 50)
    mode_label.add_theme_font_size_override("font_size", 20)
    add_child(mode_label)

func _process(_delta):
    mode_label.text = "Mode: %s" % GameMode.get_mode_name()
    mode_label.modulate = Color.GREEN if GameMode.current_mode != GameMode.Mode.NONE else Color.RED
Implementation Order

Phase 1 First - Add GameMode singleton and test mode switching
Test - Verify mode changes work and print correctly
Phase 2 - Update battle systems one at a time, testing each
Test - Verify battle systems stop during PID tuning
Phase 3-4 - Add observer and refactor PIDTuner
Test - Verify PID tuning works without interference
Phase 5-6 - Fix ship resets and update ModeSelector
Final Test - Full PID tuning sequence

Success Criteria

No PDC activity during PID tuning - Console should be clean
No BattleManager activation - No "BATTLE STARTED" messages
Ships reset properly - Visual confirmation of teleportation
Clean cycle output - Only PID tuning messages in console
Successful tuning - Reaches 50 consecutive perfect volleys

Potential Issues to Watch

Signal timing - Mode change signals might arrive before some systems are ready
Deferred calls - Position resets might need set_deferred to avoid physics conflicts
Cleanup edge cases - Make sure all entities are removed between modes
Autoload order - GameMode must load before TunerSystem

This architecture creates a clean, mode-based separation where systems literally cannot interfere with each other. The immediate-state approach for PID tuning removes all the fragile callback dependencies, making it much more robust.