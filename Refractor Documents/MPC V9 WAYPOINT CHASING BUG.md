# COMPREHENSIVE ANALYSIS REPORT: MPC V9 WAYPOINT CHASING BUG
## Technical Incident Report & Resolution Plan

---

## EXECUTIVE SUMMARY

After 6+ hours of debugging, we have identified a critical flaw in the GPU-based Model Predictive Control (MPC) torpedo guidance system implementation that causes waypoints to "chase" torpedoes instead of maintaining fixed ahead positions. This violates the core physics-first design principles outlined in the MPC Refactor Document v9.0 and renders the guidance system non-functional.

The issue stems from three interconnected problems: (1) incorrect GPU shader start position logic, (2) a circular feedback loop in continuation point calculation, and (3) failure of the waypoint protection system. These issues combine to create the visual effect where waypoints appear to "teleport" to torpedo positions every 1-3 seconds instead of providing stable navigation targets.

---

## BACKGROUND & CONTEXT

### The Space Combat Simulation Project

This project implements a sophisticated space combat simulation in Godot 4.x featuring:
- **Physics-based torpedo guidance** using forward-only thrust (no lateral/reverse thrust)
- **GPU compute shaders** for real-time trajectory optimization
- **Multi-layered guidance system** (Layer 1: trajectory planning, Layer 2: execution)
- **Real-world physics constraints** including turn radius = v²/a and flip-burn maneuvers
- **Multiple torpedo types** (Straight, Multi-Angle, Simultaneous Impact)

### The Performance Challenge

The original system faced fundamental scalability issues:
- CPU-based MPC calculations couldn't handle multiple torpedoes
- Template-based approaches created jerky, unrealistic motion
- Circular dependencies between systems caused update stampedes
- Lack of true physics validation led to impossible maneuvers

### The V9 Refactor Initiative

The MPC Refactor Document v9.0 was created to address these issues through a complete architectural overhaul focusing on:
1. **Physics-first implementation** with proper velocity/acceleration constraints
2. **GPU-only trajectory planning** (no CPU fallback)
3. **Pull-based update system** to eliminate stampedes
4. **Clean data architecture** with single responsibility principles
5. **Event-based communication** to break circular dependencies

---

## THE MPC REFACTOR DOCUMENT V9.0 - GOALS AND ARCHITECTURE

### Core Design Principles

The refactor document establishes several fundamental principles:

**Physics Constraints:**
- Forward-only thrust (torpedoes can't thrust sideways or backwards)
- Continuous acceleration (30G baseline, up to 150G for maneuvers)
- Turn radius = v²/a (emerges from physics, not programmed)
- No arbitrary speed limits (only physics limits)

**Flip-and-Burn Navigation:**
The document identifies flip-burn as the fundamental solution to high-velocity navigation:
1. **Acceleration Phase**: Thrust toward desired position (100-150G)
2. **Flip Phase**: Rotate 180° while coasting (2-3 seconds)  
3. **Deceleration Phase**: Thrust retrograde to reduce velocity
4. **Maneuver Phase**: Execute trajectory at manageable velocity

**Example Physics Problem:** At 91,000 m/s, turn radius = 5,633 km. For a 4,000 km engagement, the torpedo would need to start turning before launch - physically impossible without flip-burn.

### Clean Data Architecture

The V9 design mandates strict architectural principles:

**Single Responsibility:**
- **BatchMPCManager**: Scheduling & coordination only
- **TrajectoryPlanner**: GPU trajectory generation only  
- **TorpedoBase**: State & execution only
- **ProportionalNavigation**: Moment-to-moment control only

**Pull-Based Updates:**
```
Every 1-3Hz (based on time-to-impact):
BatchMPCManager timer tick →
BatchMPCManager collects all torpedo states →
TrajectoryPlanner executes GPU computation →
GPU returns new waypoints for all torpedoes →
BatchMPCManager applies waypoints to each torpedo
```

**Waypoint Protection System:**
The document specifies that waypoints 0-2 should be "protected" from updates to prevent the exact chasing behavior we're experiencing:
> "Only waypoints 3+ positions ahead should update, waypoints 0-2 should be 'protected'"

### Expected Behavior vs. Current Bug

**What Should Happen (per V9 design):**
- Waypoints spawn ahead of torpedo and stay in fixed positions
- Torpedoes fly TO waypoints, not have waypoints come TO them
- Only waypoints 3+ positions ahead update
- Waypoints include velocity profiles for smooth acceleration/deceleration

**What's Actually Happening (the bug):**
- Waypoints spawn directly on top of torpedoes
- Every 1-3 seconds, waypoints "teleport" to torpedo's current position
- Torpedoes never "reach" waypoints because waypoints keep moving
- No breadcrumb trail of completed waypoints

---

## CURRENT IMPLEMENTATION ANALYSIS

### System Components (As Implemented)

**BatchMPCManager.gd:**
- Implements pull-based timer system (1-3Hz updates)
- Collects torpedo states with zero-trust validation
- Calculates continuation points from existing waypoints
- Sends batched requests to TrajectoryPlanner
- Applies results back to torpedoes

**TrajectoryPlanner.gd:**
- GPU-only implementation (no CPU fallback)
- Uses compute shader `trajectory_planning_v9.glsl`
- Handles batched waypoint generation
- Validates trajectory physics
- Returns waypoint arrays with velocity profiles

**TorpedoBase.gd:**
- Enhanced waypoint class with velocity targets
- ProportionalNavigation component for execution
- Trail quality visualization
- Waypoint acceptance logic

**trajectory_planning_v9.glsl:**
- GPU compute shader for waypoint generation
- Supports multiple trajectory types (straight, multi-angle, simultaneous)
- Physics validation and flip-burn detection
- Outputs structured waypoint data

### Data Flow (As Designed)

```
Timer (1-3Hz) → BatchMPCManager.collect_torpedo_states() →
Calculate continuation_position from waypoints[current_index + 3] →
TrajectoryPlanner.generate_waypoints_batch() →
GPU shader execution →
Results applied to torpedoes →
Visual update
```

### The Debug Investigation Process

Three comprehensive debug sessions were conducted:

**Debug Session 1: Enhanced Logging**
- Added detailed logs to BatchMPCManager
- GPU input/output position tracking
- Waypoint update event logging
- Discovered coordinate discrepancies

**Debug Session 2: Visualizer Correlation**
- Added current waypoint highlighting
- Cross-referenced log positions with visual positions
- Confirmed visual chasing behavior
- Identified mixed torpedo behaviors

**Debug Session 3: Data Flow Tracing**
- Complete 712-line debug log captured
- Full data flow from BatchMPC → GPU → Results → Torpedo
- Timing analysis of update cycles
- Continuation point calculation tracking

---

## DETAILED LOG ANALYSIS & EVIDENCE

### The Smoking Gun: Confirmed Feedback Loop

The logs provide irrefutable evidence of the circular dependency:

**Cycle 1 (Initial):**
```
[BatchMPC] GPU Input for torpedo_59: current_pos=(-63960.82, 35549.33), continuation_pos=(60000, -32994.75), wp_index=0
[GPU] Torpedo 0 returned first waypoint at: (-44710.47, 41091.14)
```

**Cycle 2 (1 second later):**
```
[BatchMPC] GPU Input for torpedo_59: current_pos=(-63825.12, 35549.31), continuation_pos=(-44710.47, 41091.14), wp_index=0
[GPU] Torpedo 0 returned first waypoint at: (-44589.26, 41078.47)
```

**CRITICAL EVIDENCE:** The `continuation_pos` in Cycle 2 (-44710.47, 41091.14) is EXACTLY the waypoint the GPU returned in Cycle 1. This proves the circular dependency identified in Theory 3 of the original problem description.

### Progressive Waypoint Drift

Tracking torpedo_59 through multiple cycles shows systematic drift:

| Cycle | Torpedo Position | Continuation Position | GPU Output Waypoint |
|-------|------------------|----------------------|---------------------|
| 1 | (-63960.82, 35549.33) | (60000, -32994.75) | (-44710.47, 41091.14) |
| 2 | (-63825.12, 35549.31) | (-44710.47, 41091.14) | (-44589.26, 41078.47) |
| 3 | (-63493.23, 35548.85) | (-44589.26, 41078.47) | (-44291.91, 41046.18) |
| 4 | (-62965.14, 35547.09) | (-44291.91, 41046.18) | (-43818.51, 40993.48) |

**Pattern Analysis:** Each cycle's GPU output becomes the next cycle's continuation input, creating a feedback loop that pulls waypoints progressively closer to the torpedo's flight path instead of maintaining fixed ahead positions.

### Mixed Torpedo Behavior

The logs reveal inconsistent behavior between torpedoes:

**torpedo_59 (Anomalous):**
- Shows waypoints far from torpedo position
- Updates less frequently
- Appears to be working "better" but still exhibits chasing

**torpedo_60 (Standard Broken):**
- Shows waypoints very close to torpedo position
- More frequent updates
- Classic chasing behavior

**Key Evidence:**
```
[TorpedoVisualizer] First waypoint at: (-44589.26, 41078.47), type: cruise  (torpedo_59)
[TorpedoVisualizer] First waypoint at: (-63815.13, 35527.88), type: cruise  (torpedo_60)
```

torpedo_60's waypoint is within ~300 units of its position, while torpedo_59's is ~19,000 units away.

### Waypoint Protection Failure

The logs show protected waypoints updating every cycle:

```
[Visualizer] Drawing CURRENT waypoint 0 for torpedo_59 at (-44589.26, 41078.47) (torpedo at (-63535.25, 35548.94))
[Visualizer] Drawing CURRENT waypoint 0 for torpedo_60 at (-63815.13, 35527.88) (torpedo at (-63534.08, 35527.53))
```

Both torpedoes remain at waypoint index 0, but these "protected" waypoints are being updated every 1-3 seconds, violating the protection system design.

---

## ROOT CAUSE ANALYSIS

### Primary Cause: GPU Shader Start Position Logic

**Location:** `trajectory_planning_v9.glsl` lines 155-159

```glsl
// Calculate from continuation point if torpedo has progressed
vec2 start_position = torpedo.position;  // ← ALWAYS uses live position first
float start_velocity = length(torpedo.velocity);

// Check if we should use continuation point (index >= 1 means we've started moving)
if (torpedo.current_waypoint_index >= 1.0) {  // FIXED: Changed from > 0.5
    start_position = torpedo.continuation_position;
    start_velocity = torpedo.continuation_velocity;
}
```

**The Flaw:** For torpedoes with `current_waypoint_index = 0` (which is most torpedoes since they can't reach the chasing waypoints), the GPU shader ALWAYS uses `torpedo.position` - the live, constantly updating torpedo position - instead of the carefully calculated `continuation_position`.

**Why This Breaks Everything:** The shader generates waypoints starting from where the torpedo currently is, not from a fixed planning point ahead. This violates the fundamental principle that waypoints should be stable navigation targets.

### Secondary Cause: Feedback Loop in Continuation Calculation

**Location:** `BatchMPCManager.gd` lines 89-98

```gdscript
# Find the continuation point (2-3 waypoints ahead)
var continuation_index = min(current_wp_index + 3, waypoints.size() - 1)
var continuation_position = pos  # Default to current position
var continuation_velocity = 2000.0  # Default velocity

if continuation_index < waypoints.size() and waypoints.size() > 0 and continuation_index != current_wp_index:
    var continuation_wp = waypoints[continuation_index]
    continuation_position = continuation_wp.position  # ← Using GPU-generated waypoint as input!
    continuation_velocity = continuation_wp.velocity_target
```

**The Problem:** This creates a perfect circular dependency:
1. GPU generates waypoints based on torpedo state
2. BatchMPC extracts waypoint[current_index + 3] as continuation point
3. Next cycle uses that waypoint position as GPU input
4. GPU generates new waypoints based on its own previous output
5. Cycle repeats indefinitely

### Tertiary Cause: Protection System Bypass

The waypoint protection system has bypass conditions that are being triggered, allowing waypoints 0-2 to be updated when they should remain stable.

**Evidence:** Torpedoes remain at `current_waypoint_index = 0` because they can never reach the constantly moving waypoints, but these supposedly "protected" waypoints are updating every cycle.

### The Compounding Effect

These three issues create a compounding failure mode:

1. **Shader uses wrong start position** → waypoints generated at torpedo location
2. **Feedback loop** → waypoints become input for next calculation
3. **Protection failure** → no stability mechanism to break the cycle
4. **Unreachable waypoints** → torpedoes never advance to index 1+
5. **Perpetual index 0** → shader always uses torpedo.position
6. **Cycle repeats** → visual "chasing" behavior

---

## DETAILED FIX PLAN

### Phase 1: GPU Shader Logic Correction (CRITICAL)

**Objective:** Ensure consistent trajectory planning from stable reference points

**File:** `Shaders/trajectory_planning_v9.glsl`

**Current Problem Code:**
```glsl
vec2 start_position = torpedo.position;
if (torpedo.current_waypoint_index >= 1.0) {
    start_position = torpedo.continuation_position;
}
```

**Solution Option A (Recommended):**
```glsl
// Always use continuation position for consistent trajectory planning
vec2 start_position = torpedo.continuation_position;
float start_velocity = torpedo.continuation_velocity;
```

**Solution Option B (Conservative):**
```glsl
// Use continuation position by default, fallback to torpedo position only if continuation is invalid
vec2 start_position = torpedo.continuation_position;
float start_velocity = torpedo.continuation_velocity;

// Sanity check - if continuation position is impossibly far, use torpedo position
float continuation_distance = distance(torpedo.position, torpedo.continuation_position);
if (continuation_distance > 100000.0) {  // 100km sanity limit
    start_position = torpedo.position;
    start_velocity = length(torpedo.velocity);
}
```

**Rationale:** Option A aligns with the V9 architecture principle that trajectory planning should occur from stable reference points, not moving targets. Option B provides a safety net for edge cases.

### Phase 2: Break the Feedback Loop

**Objective:** Eliminate circular dependency in continuation point calculation

**File:** `Scripts/Systems/BatchMPCManager.gd`

**Current Problem Code:**
```gdscript
var continuation_index = min(current_wp_index + 3, waypoints.size() - 1)
if continuation_index < waypoints.size() and waypoints.size() > 0:
    var continuation_wp = waypoints[continuation_index]
    continuation_position = continuation_wp.position  // Using GPU waypoints as input!
```

**Solution:**
```gdscript
func calculate_stable_continuation_point(torpedo: Node2D, target: Node2D) -> Vector2:
    # Calculate continuation point based on target trajectory, not previous waypoints
    var to_target = target.global_position - torpedo.global_position
    var distance = to_target.length()
    var direction = to_target.normalized()
    
    # Project ahead based on current velocity and trajectory
    var velocity_direction = torpedo.velocity_mps.normalized()
    var speed = torpedo.velocity_mps.length()
    
    # Calculate stable planning point 3-5 seconds ahead
    var planning_time = 3.0  # seconds
    var planning_distance = speed * planning_time
    
    # Blend velocity direction with target direction for smooth continuation
    var blend_factor = clamp(distance / 10000.0, 0.3, 0.8)  # Closer to target = more target-focused
    var continuation_direction = velocity_direction.lerp(direction, blend_factor).normalized()
    
    return torpedo.global_position + continuation_direction * planning_distance
```

**Alternative Approach - Target-Based Continuation:**
```gdscript
func calculate_target_based_continuation(torpedo: Node2D, target: Node2D) -> Vector2:
    # Always plan from a point between torpedo and target
    var to_target = target.global_position - torpedo.global_position
    var distance = to_target.length()
    
    # Use fixed fraction of distance to target as continuation point
    var continuation_fraction = 0.3  # 30% of way to target
    return torpedo.global_position + to_target * continuation_fraction
```

### Phase 3: Strengthen Waypoint Protection

**Objective:** Ensure waypoints 0-2 remain stable once set

**File:** `Scripts/Entities/Weapons/TorpedoBase.gd`

**Current Problem:** Protection logic has bypass conditions that allow updates

**Solution:**
```gdscript
func apply_waypoint_update(new_waypoints: Array, protected_count: int):
    # STRICT protection - never update waypoints 0-2 once torpedo is in flight
    if has_started_movement and current_waypoint_index < 3:
        # Only allow updates to waypoints beyond current + protected_count
        var update_start_index = max(current_waypoint_index + protected_count, 3)
        
        # Preserve all waypoints up to update_start_index
        var preserved = []
        for i in range(min(update_start_index, waypoints.size())):
            preserved.append(waypoints[i])
        
        # Add new waypoints only beyond the protected zone
        for i in range(max(0, update_start_index - preserved.size())):
            if i < new_waypoints.size():
                preserved.append(new_waypoints[i])
        
        waypoints = preserved
    else:
        # Initial waypoint setting or torpedo hasn't started moving
        waypoints.clear()
        waypoints.append_array(new_waypoints)
```

### Phase 4: Improve Waypoint Acceptance Logic

**Objective:** Help torpedoes advance through waypoints properly

**Enhanced Acceptance Logic:**
```gdscript
func should_accept_waypoint(torpedo_pos: Vector2, torpedo_vel: Vector2, waypoint: Waypoint) -> bool:
    var pos_error = waypoint.position.distance_to(torpedo_pos) * WorldSettings.meters_per_pixel
    var vel_error = abs(waypoint.velocity_target - torpedo_vel.length())
    
    # Standard position acceptance
    if pos_error < 500.0:  # 500m radius
        return true
    
    # Velocity-based acceptance for high-speed passes
    if torpedo_vel.length() > 5000.0 and vel_error < waypoint.velocity_tolerance:
        # Check if we're moving generally toward the waypoint
        var to_waypoint = waypoint.position - torpedo_pos
        var heading_alignment = torpedo_vel.normalized().dot(to_waypoint.normalized())
        
        # Accept if we're moving toward it and velocity is close
        if heading_alignment > 0.3 and pos_error < 2000.0:  # 2km for high-speed
            return true
    
    # Overshoot protection - if we've passed the waypoint, accept it
    if has_passed_waypoint(torpedo_pos, torpedo_vel, waypoint):
        return true
    
    return false

func has_passed_waypoint(torpedo_pos: Vector2, torpedo_vel: Vector2, waypoint: Waypoint) -> bool:
    # Check if torpedo has overshot the waypoint
    var to_waypoint = waypoint.position - torpedo_pos
    var velocity_dot = torpedo_vel.dot(to_waypoint)
    
    # If velocity is pointing away from waypoint and we're close, we've passed it
    return velocity_dot < 0 and to_waypoint.length() < 1000.0
```

---

## IMPLEMENTATION STRATEGY

### Step 1: Minimal Reproduction Test

Before implementing fixes, create a minimal test case:

```gdscript
# In scene ready function
func test_single_torpedo_waypoint_generation():
    # Fire single torpedo
    # Enable debug logging for that torpedo only
    # Observe 5-10 update cycles
    # Document expected vs actual waypoint positions
```

### Step 2: Staged Rollout

**Stage 1: GPU Shader Fix Only**
- Implement Option A (always use continuation_position)
- Test with existing system
- Measure improvement in waypoint stability

**Stage 2: Feedback Loop Break**
- Implement stable continuation point calculation
- Test that waypoints no longer chase torpedo positions
- Verify torpedoes can reach waypoints

**Stage 3: Protection System**
- Strengthen waypoint protection logic
- Test that early waypoints remain stable
- Verify breadcrumb trail formation

**Stage 4: Acceptance Logic**
- Improve waypoint acceptance for high-speed scenarios
- Test torpedo progression through waypoint sequence
- Verify proper index advancement

### Step 3: Validation Testing

**Test Cases:**
1. **Single Straight Torpedo:** Basic functionality test
2. **Multiple Torpedoes:** Batch processing validation  
3. **High-Speed Scenario:** Flip-burn trajectory validation
4. **Multi-Angle Approach:** Complex trajectory validation
5. **Simultaneous Impact:** Coordinated trajectory validation

**Success Criteria:**
- Waypoints spawn ahead of torpedoes and remain fixed
- Torpedoes advance through waypoint sequence (index 0→1→2→3...)
- Visual trail shows completed waypoints in grey
- No waypoint "teleporting" or chasing behavior
- GPU performance remains under 10ms for 8 torpedoes

---

## TESTING & VALIDATION PLAN

### Debug Configuration

```gdscript
# Enable specific debug categories for validation
DebugConfig.categories = {
    "mpc_batch_updates": true,
    "waypoint_system": true, 
    "torpedo_init": true,
    "proportional_nav": false,  # Disable noisy logs
    "gpu_boundary": false,
    "pdc_targeting": false
}
```

### Validation Metrics

**Quantitative Measures:**
- Waypoint stability: Position variance over time < 100 pixels
- Progression rate: Torpedoes advance waypoint index within expected timeframe
- System performance: GPU compute time < 10ms for 8 torpedoes
- Hit accuracy: >80% of torpedoes reach target within 5% distance error

**Qualitative Measures:**
- Visual behavior matches V9 design expectations
- No observable "chasing" or "teleporting" of waypoints
- Smooth torpedo motion through waypoint sequence
- Proper breadcrumb trail visualization

### Long-term Monitoring

**Performance Regression Testing:**
- Automated tests for waypoint stability
- GPU performance benchmarks
- Physics validation checks
- Multi-torpedo coordination accuracy

---

## CONCLUSION

This comprehensive analysis reveals that the waypoint chasing bug results from a fundamental mismatch between the V9 architecture design and the actual GPU shader implementation. The circular feedback loop between BatchMPCManager and TrajectoryPlanner, combined with incorrect start position logic in the GPU shader, creates a system that fights against its own design principles.

The fix requires surgical precision: correcting the GPU shader logic to use stable reference points, breaking the feedback loop in continuation point calculation, and strengthening the waypoint protection system. These changes will restore the physics-first, stable trajectory planning behavior outlined in the MPC Refactor Document v9.0.

The 6-hour debugging session, while frustrating, has provided invaluable insight into the complex interactions between GPU compute shaders, batch processing systems, and real-time physics simulation. The comprehensive logging and systematic analysis documented here will serve as a reference for future trajectory planning system development and debugging.

**Estimated Implementation Time:** 4-6 hours
**Risk Level:** Medium (core system changes)  
**Expected Outcome:** Complete resolution of waypoint chasing behavior and restoration of proper MPC trajectory planning functionality.