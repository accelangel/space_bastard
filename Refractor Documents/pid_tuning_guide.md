# PID Auto-Tuning System Implementation Guide

## Overview
This document outlines the implementation of an automated PID tuning system for the torpedo guidance system. The tuner will sequentially optimize all three torpedo trajectory types (straight, multi-angle, and simultaneous impact) using gradient descent with normalized gains that work at any torpedo speed.

## System Goals
- Create a one-button automated tuning system that finds optimal PID values for all trajectory types
- Use normalized PID gains that work identically at 2000 m/s, 5000 m/s, or any other speed
- Prevent manual intervention during tuning to ensure consistent results
- Provide clear progress feedback and final values for manual implementation

## Architecture Overview

### New Components
1. **PIDTuner.gd** - A new autoload singleton that manages the entire tuning process
2. **Modified Systems** - Updates to existing scripts to support tuning mode

### Key Design Principles
- **Separation of Concerns**: PIDTuner only manages tuning; it doesn't fire torpedoes or control ships directly
- **Non-Invasive**: Existing game systems continue to work normally when not tuning
- **Safety First**: Multiple safeguards prevent crashes and invalid states
- **Clear Feedback**: Console output shows exactly what's happening at each step

## Core Problem Being Solved

### The Speed Scaling Problem
Traditional PID gains are dependent on the system's operating speed. A tune that works at 2000 m/s will oscillate wildly at 5000 m/s. This is because the raw PID gains have units that depend on the velocity scale.

### The Solution: Normalized PID
By dividing all errors by the maximum speed before applying gains, we create dimensionless normalized gains that work at any speed:
```gdscript
normalized_error = velocity_error / max_speed_mps
# Apply normalized gains
pid_output = normalized_gains * max_speed_mps
```

## Implementation Components

### 1. Critical Bug Fix - PDCSystem.gd

**Problem**: The game crashes when torpedoes go out of bounds because PDCSystem tries to call methods on freed torpedo references.

**Root Cause**: When a torpedo calls `queue_free()`, it's not immediately removed from memory. PDCSystem still holds a reference and tries to validate it next frame, causing a crash.

**Solution**: Add instance validation BEFORE any method calls:
- Check `is_instance_valid()` before calling any methods
- Check `is_queued_for_deletion()` as additional safety
- Only then call validation methods

**Additional Change**: Add an `enabled` flag so PIDTuner can disable all PDCs during tuning.

### 2. Torpedo.gd Modifications

#### Miss Detection System
A torpedo is considered "missed" when:
- It has passed the target and is moving away (velocity dot product negative)
- This condition persists for 2 seconds (prevents false positives during maneuvers)
- OR it exceeds maximum lifetime of 30 seconds

When a miss is detected:
1. Report performance data to PIDTuner
2. Self-destruct cleanly without errors
3. Handle out-of-bounds cases gracefully

#### Normalized PID Implementation
- Replace the existing PID controller with normalized version
- Normalize velocity error, integral, and derivative by `max_speed_mps`
- Store separate PID values for each trajectory type
- Allow runtime updates from PIDTuner

#### Performance Reporting
- Report successful hits with time-to-impact
- Report misses with closest approach distance
- Report to PIDTuner for analysis

### 3. PIDTuner.gd - The Tuning Engine

#### Core Responsibilities
- Manage the three-phase tuning process (straight → multi-angle → simultaneous)
- Reset ship positions and velocities between cycles
- Clean up any remaining torpedoes
- Disable PDCs and battle reports during tuning
- Track performance metrics
- Apply gradient descent to optimize PID gains
- Provide clear console output

#### Tuning Process Flow
1. **Initialization**: Disable PDCs, disable battle reports, clear the field
2. **Reset Phase**: Position ships at consistent starting locations, zero all velocities
3. **Fire Phase**: Request torpedo volley from launcher
4. **Track Phase**: Wait for all 8 torpedoes to hit or miss
5. **Analysis Phase**: Calculate cost function based on hit rate and miss distances
6. **Optimization Phase**: Apply gradient descent to update PID gains
7. **Repeat**: Continue until 50 consecutive perfect volleys achieved

#### Ship Movement and Reset Behavior
- **During Each Cycle**: Ships move exactly as they currently do in normal gameplay
  - Player ship accelerates at 1.0G in its test direction
  - Enemy ship accelerates at 0.02G in its test direction
  - Ships maintain their velocities and continue accelerating throughout the cycle
- **After Each Cycle**: Ships reset to their exact starting positions
  - Player ship returns to `Vector2(-64000, 35500)` with 45° rotation
  - Enemy ship returns to `Vector2(55000, -28000)` with -135° rotation
  - Both ships have their velocities reset to `Vector2.ZERO`
  - This ensures identical starting conditions for every cycle

#### Perfect Cycle Requirement
- **Success Criteria**: 50 consecutive perfect volleys (8/8 hits) with no misses
- **Reset on Failure**: If even one torpedo misses in a volley, the consecutive count resets to 0
- **Example**: 49 perfect volleys followed by a 7/8 result means starting over at 0
- This ensures the final PID values are truly robust and consistent

#### Gradient Descent Implementation
- Perturb each parameter (Kp, Ki, Kd) by ±1% to estimate gradient
- Calculate cost function: `cost = (1 - hit_rate) * 100 + avg_miss_distance * 0.001`
- Update parameters in direction of decreasing cost
- Use adaptive learning rate that decreases as convergence improves

#### Phase Management
- **Phase 1**: Tune STRAIGHT trajectory until 50 consecutive perfect cycles
- **Phase 2**: Tune MULTI_ANGLE trajectory until 50 consecutive perfect cycles  
- **Phase 3**: Tune SIMULTANEOUS trajectory until 50 consecutive perfect cycles
- **Complete**: Display all optimal values for manual implementation

### 4. Supporting Modifications

#### BattleManager.gd
- Add `reports_enabled` flag
- Skip battle analysis during PID tuning to keep console clean
- Prevents ~60 lines of battle report after each tuning cycle

#### TorpedoLauncher.gd
- Add method for PIDTuner to request test volleys
- Temporarily override trajectory type based on current tuning phase
- Ensure consistent 8-torpedo volleys

#### PlayerShip.gd
- Connect SPACE key to start/stop tuning
- Disable manual torpedo firing during tuning
- Pass control to PIDTuner when active

## What NOT to Do

### Don't Mix Responsibilities
- PIDTuner should NOT directly fire torpedoes (use launcher)
- PIDTuner should NOT move ships (just reset positions)
- PIDTuner should NOT modify battle logic (just disable reports)

### Don't Use Non-Normalized PID
- Raw PID gains will NOT work at different speeds
- Each speed would need completely different tuning
- Map size changes would break the tune

### Don't Allow Interference
- Manual torpedo firing during tuning will corrupt results
- PDCs shooting down test torpedoes ruins the data
- Ship movement during cycles creates inconsistent conditions

### Don't Ignore Edge Cases
- Torpedoes going out of bounds MUST be handled gracefully
- Freed references MUST be checked before use
- Infinite loops MUST have timeout protection

### Don't Accept Imperfect Results
- A single miss resets the consecutive count to zero
- No averaging or "good enough" - only perfect volleys count
- This ensures the final tune is rock-solid

## Console Output Design

Keep output minimal and informative:
```
========================================
    PID AUTO-TUNING ACTIVE
    Phase 1/3: STRAIGHT TRAJECTORY
    Press SPACE to stop
========================================
Cycle 23 | Gains: Kp=0.245, Ki=0.032, Kd=0.087
Resetting positions... Firing volley...
Result: 8/8 hits | Consecutive: 12/50
Gradient: ∇[-0.003, +0.001, -0.002] | LR: 0.05
Next cycle in 2s...

Cycle 24 | Gains: Kp=0.242, Ki=0.033, Kd=0.085
Resetting positions... Firing volley...
Result: 7/8 hits | 1 miss (overshot by 45m)
IMPERFECT VOLLEY - Resetting consecutive count to 0
Gradient: ∇[-0.005, +0.002, -0.003] | LR: 0.05
Next cycle in 2s...
```

## Success Criteria

The tuning is complete when:
- All three trajectory types achieve 50 consecutive perfect volleys (100% hit rate)
- No oscillations observed in terminal guidance
- Total tuning time is reasonable (< 30 minutes)
- Final values work at any torpedo speed without modification

## Final Output Format

```
========================================
    PID TUNING COMPLETE
========================================
Add these values to Torpedo.gd:

const PID_VALUES = {
    "straight": {"kp": 0.223, "ki": 0.028, "kd": 0.095},
    "multi_angle": {"kp": 0.287, "ki": 0.041, "kd": 0.112},
    "simultaneous": {"kp": 0.302, "ki": 0.044, "kd": 0.125}
}

Total cycles: 487
Total time: 12m 34s
Perfect streak achieved: 50 consecutive volleys per mode
========================================
```

## Implementation Order

1. **Fix Critical Bugs First**
   - PDCSystem.gd reference validation
   - Torpedo.gd out-of-bounds handling

2. **Add Core Features**
   - Normalized PID in Torpedo.gd
   - Miss detection system
   - Performance reporting

3. **Create PIDTuner.gd**
   - Implement as autoload singleton
   - Add all tuning logic

4. **Wire Up Integration**
   - Connect SPACE key
   - Add disable flags
   - Test each phase

## Testing Recommendations

1. Test with a single tuning cycle first
2. Verify ships reset properly to starting positions
3. Confirm ships maintain their test accelerations during cycles
4. Confirm PDCs stay disabled
5. Check console output formatting
6. Verify consecutive count resets on any miss
7. Run full auto-tune sequence
8. Verify tuned values work at different speeds

## Key Implementation Details

### Ship Starting Configuration
```gdscript
# Player ship
position: Vector2(-64000, 35500)
rotation: 0.785398  # 45 degrees
test_acceleration: true
test_direction: Vector2(1, -1).normalized()
test_gs: 1.0

# Enemy ship  
position: Vector2(55000, -28000)
rotation: -2.35619  # -135 degrees
test_acceleration: true
test_direction: Vector2(1, -1).normalized()
test_gs: 0.02
```

### Reset Function Pseudocode
```gdscript
func reset_battle_positions():
    # Reset player ship
    player.global_position = player_start_pos
    player.rotation = player_start_rot
    player.velocity_mps = Vector2.ZERO
    # Ship will resume its test acceleration automatically
    
    # Reset enemy ship
    enemy.global_position = enemy_start_pos
    enemy.rotation = enemy_start_rot  
    enemy.velocity_mps = Vector2.ZERO
    # Ship will resume its test acceleration automatically
```

This ensures each tuning cycle starts with identical conditions while allowing the ships to move naturally during the cycle, providing realistic moving target scenarios for the torpedoes.