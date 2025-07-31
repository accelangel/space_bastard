# Space Combat Torpedo Control System Refactor Plan
## 3-Layer Architecture for Standard Direct Attack Torpedoes

---

## CURRENT SITUATION ANALYSIS

### The V9 Waypoint Chasing Crisis

After 6 days of debugging, the core V9 problem remains: **waypoints chase torpedoes instead of torpedoes flying to waypoints.** The system fights against physics with discrete waypoint management when space combat demands continuous guidance.

**V9 Architecture Problems:**
- **Circular Dependencies**: BatchMPCManager ↔ TrajectoryPlanner ↔ Torpedo feedback loops
- **Over-Engineering**: 40+ parameters for managing discrete waypoint behaviors  
- **Debugging Nightmare**: Multiple systems all touching the same data with unclear ownership
- **Physics Mismatch**: Forcing smooth curves through discrete points at extreme velocities

### The Simple Solution Philosophy

**From:** "Complex waypoint planning with multi-torpedo coordination"  
**To:** "Each torpedo independently flies directly at its target"

**Focus:** Get ONE thing working perfectly - standard direct attack torpedo with natural physics.

---

## THE 3-LAYER SOLUTION ARCHITECTURE

### Fundamental Philosophy
**"Point at target, fly directly there, hit it nose-first"**

No flip-burn maneuvers, no angle requirements, no coordination - just reliable direct attacks with good terminal approach behavior.

### The Three Layers for Standard Torpedo

## Layer 1: Mission Layer (1 Hz)
**Responsibility:** Simple target assignment  
**For Standard Torpedo:** "Attack assigned target directly"  

```gdscript
# Mission Layer Data Structure
class MissionDirective:
    var target_node: Node2D         # What to attack
    var attack_priority: int        # Engagement priority
    var abort_conditions: Array     # When to give up
    var mission_start_time: float   # When mission began
```

**Mission Layer Responsibilities:**
- Assign target to torpedo
- Determine when mission should abort
- Handle target switching if original target destroyed
- Set engagement priority level

## Layer 2: Guidance Layer (10 Hz)  
**Responsibility:** Calculate optimal direct path to target  
**For Standard Torpedo:** Target prediction + direct line trajectory

```gdscript
# Guidance Layer Data Structure
class GuidanceState:
    var desired_position: Vector2     # Where torpedo should be aiming
    var desired_velocity: Vector2     # What velocity vector toward target
    var desired_heading: float        # Point toward target
    var thrust_level: float          # 1.0 for acceleration, 0.5 for terminal
    var guidance_mode: String        # "accelerate" or "terminal"
    var time_to_impact: float        # Estimated seconds to target
    var target_prediction: Vector2   # Where target will be at impact
```

**Guidance Layer Responsibilities:**
- Predict target position at intercept time
- Calculate optimal intercept trajectory
- Determine flight phase (acceleration vs terminal)
- Estimate time to impact
- Handle target movement and course corrections

## Layer 3: Control Layer (60 Hz)
**Responsibility:** Execute Proportional Navigation toward guidance target  
**For Standard Torpedo:** Simple PN + thrust management

```gdscript
# Control Layer Data Structure
class ControlCommands:
    var thrust_magnitude: float      # 0.0-1.0 thrust level
    var rotation_rate: float         # rad/s to orient toward target
    var control_mode: String         # "normal", "terminal", "coast"
    var alignment_quality: float     # How well aligned with velocity vector
```

**Control Layer Responsibilities:**
- Execute Proportional Navigation guidance law
- Manage thrust for acceleration/deceleration phases
- Smooth control inputs to prevent jittery behavior
- Maintain good alignment between orientation and velocity

---

## STANDARD TORPEDO BEHAVIOR

### Flight Profile Phases
1. **Launch Phase**: Orient toward target, begin acceleration
2. **Acceleration Phase**: Full thrust directly toward predicted intercept point  
3. **Mid-Course Phase**: PN guidance handles target movement and course corrections
4. **Terminal Phase**: Reduce thrust for better accuracy and PDC cross-section
5. **Impact Phase**: Nose-first collision at manageable velocity

### Key Physics Principles
- **No Flip-Burn**: Standard torpedoes don't need complex maneuvers
- **Direct Path**: Straight line to target with PN corrections
- **Terminal Deceleration**: Slow down for final approach (better accuracy + smaller PDC target)
- **Natural Alignment**: Thrust direction creates natural nose-first orientation

### Phase Transition Logic
```gdscript
# Guidance Layer determines phase transitions
class PhaseManager:
    var current_phase: String
    var phase_start_time: float
    var distance_to_target: float
    var terminal_phase_distance: float = 2000.0  # meters
    
    # Phase transition conditions
    # accelerate → terminal: distance < terminal_phase_distance
    # terminal → impact: collision detection
```

---

## TUNING SYSTEM DESIGN

### Event-Based Cycle Management

**Cycle State Machine:**
```gdscript
# Tuning Mode States
enum TuningState {
    WAITING_TO_FIRE,     # Ready to launch next torpedo
    TORPEDO_IN_FLIGHT,   # Monitoring active torpedo
    ANALYZING_RESULTS,   # Processing hit/miss data
    RESETTING_SCENARIO   # Restoring ship positions
}
```

**Event-Driven Transitions:**
- `torpedo_launched` → TORPEDO_IN_FLIGHT
- `torpedo_hit_target` → ANALYZING_RESULTS  
- `torpedo_missed_target` → ANALYZING_RESULTS
- `torpedo_timed_out` → ANALYZING_RESULTS
- `analysis_complete` → RESETTING_SCENARIO
- `scenario_reset_complete` → WAITING_TO_FIRE

### Ultra-Simple Parameter Set

```gdscript
# Tuning Parameters (CPU-based calculations)
class StandardTorpedoParameters:
    var navigation_constant: float = 3.0     # 2.0-5.0, PN aggressiveness
    var terminal_deceleration: float = 0.6   # 0.3-1.0, thrust reduction in terminal phase
    
    # Parameter bounds for UI sliders
    var nav_constant_min: float = 2.0
    var nav_constant_max: float = 5.0
    var terminal_decel_min: float = 0.3
    var terminal_decel_max: float = 1.0
```

### Performance Metrics Collection

```gdscript
# Metrics tracked per cycle
class CycleMetrics:
    var flight_time: float           # Seconds from launch to impact/miss
    var hit_result: bool             # true = hit, false = miss
    var miss_distance: float         # Distance from target at closest approach
    var terminal_alignment: float    # Nose-first quality at impact
    var average_speed: float         # Average velocity during flight
    var control_smoothness: float    # How smooth the control inputs were
```

### Tuning UI Architecture

```gdscript
# UI Data Structure
class TuningUIState:
    var current_cycle: int
    var total_hits: int
    var total_cycles: int
    var hit_percentage: float
    var recent_metrics: Array[CycleMetrics]  # Last 10 cycles
    var parameter_values: StandardTorpedoParameters
    var auto_fire_enabled: bool
    var torpedo_status: TorpedoStatus  # Live torpedo data
```

**UI Layout Structure:**
```
╔══════════════════════════════════════════════════════════════╗
║                STANDARD TORPEDO TUNING MODE                  ║
╠══════════════════════════════════════════════════════════════╣
║ Auto-Fire: [✓] ON        Torpedo Type: Standard Direct      ║
║ Cycle: 8     Hits: 6/8 (75%)     Last Result: HIT          ║
║ Avg Flight Time: 4.2s    Avg Miss Distance: 245m           ║
║                                                              ║
║ ┌──────────────────────────────────────────────────────────┐ ║
║ │                    PARAMETERS                            │ ║
║ │ Navigation Constant:    [====|----] 3.2                 │ ║
║ │ Terminal Deceleration:  [===|-----] 0.6                 │ ║
║ └──────────────────────────────────────────────────────────┘ ║
║                                                              ║
║ ┌──────────────────────────────────────────────────────────┐ ║
║ │                 LIVE TORPEDO STATUS                      │ ║
║ │ Phase: Terminal Approach                                 │ ║
║ │ Speed: 2,340 m/s                                         │ ║
║ │ Distance to Target: 1,200m                               │ ║
║ │ Alignment Quality: Good (12° error)                      │ ║
║ └──────────────────────────────────────────────────────────┘ ║
╚══════════════════════════════════════════════════════════════╝
```

---

## DATA FLOW ARCHITECTURE

### Clean 3-Layer Pipeline (Per Torpedo)
```
Mission Layer (1Hz):   MissionDirective → "Attack enemy ship directly"
         ↓
Guidance Layer (10Hz): GuidanceState → Calculate intercept + flight profile  
         ↓
Control Layer (60Hz):  ControlCommands → Execute PN guidance + thrust
         ↓  
Physics Engine:        Apply forces, update position/velocity
```

### Data Dependencies
```gdscript
# Clear data flow with no circular dependencies
class TorpedoDataFlow:
    # Mission Layer reads:
    var target_assignments: Dictionary  # From TuningMode or BattleManager
    
    # Guidance Layer reads:
    var mission_directive: MissionDirective  # From Mission Layer
    var torpedo_state: TorpedoPhysicsState    # From Physics
    var target_state: TargetPhysicsState      # From Physics
    
    # Control Layer reads:
    var guidance_state: GuidanceState         # From Guidance Layer
    var torpedo_state: TorpedoPhysicsState    # From Physics
    
    # Physics reads:
    var control_commands: ControlCommands     # From Control Layer
```

### No Cross-Torpedo Communication
Each torpedo maintains its own complete 3-layer stack with zero shared state between torpedoes.

### Event-Based Communication
```gdscript
# Torpedo events for tuning system
signal torpedo_launched(torpedo: StandardTorpedo)
signal torpedo_phase_changed(torpedo: StandardTorpedo, new_phase: String)
signal torpedo_hit_target(torpedo: StandardTorpedo, impact_data: ImpactData)
signal torpedo_missed_target(torpedo: StandardTorpedo, miss_data: MissData)
signal torpedo_timed_out(torpedo: StandardTorpedo)
```

---

## FILES TO DELETE

### V9 Complexity Removal
```
Scripts/Systems/BatchMPCManager.gd           - Complex coordination system
Scripts/Systems/TrajectoryPlanner.gd         - GPU waypoint generation
Scripts/Systems/ManualTuningParameters.gd    - Over-parameterized tuning
Scripts/Systems/TorpedoVisualizer.gd         - Waypoint visualization
Scripts/Entities/Weapons/SmartTorpedo.gd     - Waypoint-based torpedo
Scripts/Entities/Weapons/TorpedoBase.gd      - Complex waypoint management
Scripts/Systems/ProportionalNavigation.gd    - Over-engineered PN
Scripts/UI/ManualTuningPanel.gd             - Complex parameter interface
Shaders/trajectory_planning_v9.glsl          - Complex GPU shader
Scenes/SmartTorpedo.tscn                     - Complex torpedo scene
Scenes/ManualTuningPanel.tscn               - Complex tuning UI
```

**Total Deletion:** 11 files removed

---

## FILES TO CREATE

### Core 3-Layer System (CPU Only)
```
Scripts/Entities/Weapons/StandardTorpedo.gd  - Complete 3-layer torpedo implementation
Scripts/Systems/TorpedoMissionLayer.gd       - Mission layer logic (target assignment)
Scripts/Systems/TorpedoGuidanceLayer.gd      - Guidance calculations (CPU-based)
Scripts/Systems/TorpedoControlLayer.gd       - Control execution (PN + thrust)
Scripts/UI/StandardTorpedoTuning.gd          - Event-based tuning interface
Scenes/StandardTorpedo.tscn                  - Clean torpedo scene
Scenes/StandardTorpedoTuning.tscn           - Simple tuning UI
```

### Supporting Data Structures
```
Scripts/Data/TorpedoDataStructures.gd        - All data classes in one file
Scripts/Systems/TorpedoPhysicsState.gd       - Physics state management
```

### Optional Visualization
```
Scripts/Systems/TorpedoTrailRenderer.gd      - Simple trail visualization (no waypoints)
```

**Total Creation:** 9 files added

**Net Change:** -2 files overall, dramatically simpler architecture

---

## SYSTEM INTEGRATION

### Mode Selection Integration
```gdscript
# GameMode enum additions
enum Mode {
    NONE,
    BATTLE,
    STANDARD_TORPEDO_TUNING  # New mode
}
```

### Torpedo Launcher Integration
```gdscript
# TorpedoLauncher.gd changes
var standard_torpedo_scene = preload("res://Scenes/StandardTorpedo.tscn")

# Replace SmartTorpedo references with StandardTorpedo
# No other changes needed - launcher just instantiates different prefab
```

### Existing Systems (No Changes Needed)
- ✅ **All Ship Logic**: PlayerShip.gd, EnemyShip.gd remain unchanged
- ✅ **All PDC Systems**: PDCSystem.gd, FireControlManager.gd unchanged  
- ✅ **All Battle Management**: BattleManager.gd, BattleEventRecorder.gd unchanged
- ✅ **All UI Systems**: Camera, PiP, Grid, ModeSelector unchanged
- ✅ **All Core Systems**: WorldSettings.gd, SensorSystem.gd unchanged

---

## IMPLEMENTATION PHASES

### Phase 1: Core Architecture (Day 1-2)
**Goal:** Basic 3-layer torpedo that can hit a stationary target

**Deliverables:**
- `StandardTorpedo.gd` with 3-layer structure
- Basic `TorpedoGuidanceLayer.gd` for direct intercept calculation
- Basic `TorpedoControlLayer.gd` for PN execution
- Simple test scene

**Success Criteria:**
- Torpedo launches and flies toward target
- No waypoint chasing behavior
- Basic hit detection works

### Phase 2: Tuning System (Day 3-4)  
**Goal:** Event-based parameter tuning with performance metrics

**Deliverables:**
- `StandardTorpedoTuning.gd` with event-based cycles
- `StandardTorpedoTuning.tscn` UI implementation
- Parameter adjustment system
- Performance metrics collection

**Success Criteria:**
- Auto-fire cycle management works
- Parameter changes affect torpedo behavior
- Hit/miss statistics display correctly

### Phase 3: Terminal Phase Optimization (Day 5)
**Goal:** Nose-first terminal approach for optimal PDC cross-section

**Deliverables:**
- Terminal phase logic in guidance layer
- Alignment quality metrics
- Deceleration parameter tuning

**Success Criteria:**
- >80% hit rate with tuned parameters
- Good terminal approach alignment
- Consistent torpedo behavior

### Phase 4: Polish and Performance (Day 6)
**Goal:** Clean up rough edges and optimize performance

**Deliverables:**
- Trail visualization improvements
- Performance optimization
- Edge case handling
- Documentation

**Success Criteria:**
- Smooth operation with 8+ torpedoes
- Clean visual feedback
- No obvious bugs or edge cases

---

## SUCCESS CRITERIA

### Must Have (Phase 1-3)
- ✅ Standard torpedo flies directly toward target with no waypoint chasing
- ✅ Event-based cycle management eliminates interval-based timing
- ✅ Terminal approach creates nose-first impact for optimal PDC cross-section  
- ✅ >80% hit rate achievable with proper parameter tuning
- ✅ System scales reliably to 8+ torpedoes without coordination issues

### Should Have (Phase 3-4)
- ✅ Smooth parameter adjustment with immediate visual feedback
- ✅ Clear performance metrics showing improvement trends
- ✅ Clean trail visualization without waypoint complexity
- ✅ Stable 60 FPS performance during tuning sessions

### Could Have (Future Extensions)
- ✅ Multi-angle torpedoes using same 3-layer architecture
- ✅ Simultaneous impact coordination between torpedoes
- ✅ GPU acceleration for 250+ torpedo scenarios
- ✅ Advanced tactical behaviors (evasion, formation flying)

---

## RISK MITIGATION

### Architecture Risks
**Risk:** 3-layer separation might add unnecessary complexity  
**Mitigation:** Start with all layers in single file, separate only if needed

**Risk:** CPU calculations might be too slow for 8+ torpedoes  
**Mitigation:** Profile early, optimize hot paths, consider GPU only if proven necessary

### Implementation Risks  
**Risk:** Event-based cycles might miss edge cases  
**Mitigation:** Implement timeout fallbacks, comprehensive collision detection

**Risk:** Parameter tuning might not converge to good values  
**Mitigation:** Start with proven PN constants from aerospace literature

### Integration Risks
**Risk:** Existing systems might need modification  
**Mitigation:** Design ensures zero changes to ship/PDC/battle systems

---

This plan provides the detailed architecture and structure you need while avoiding implementation code that could contain bugs. The focus is on **what** each system does and **how** they communicate, not the specific **how** of implementation details.