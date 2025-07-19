# Battle System Architecture Refactor
## Clean Data Pipeline Design Document

### Overview
The current battle tracking system suffers from tangled responsibilities, signal chain bugs, and inconsistent data across multiple systems. This refactor implements a clean **event-driven data pipeline** where each component has exactly one responsibility and data flows in one direction.

### Core Principles
1. **Single Responsibility**: Each system does one thing perfectly
2. **Single Source of Truth**: EntityManager is the omniscient observer
3. **No Cross-Dependencies**: Systems don't coordinate with each other
4. **Event Sourcing**: All important events are recorded for analysis
5. **Clean Data Flow**: Battle events → EntityManager → BattleManager → Analysis

## Additional Requirements

### Clean Console Output
- **Battle analysis only** - Clean, readable battle report printed to console
- **Minimal debug spam** - Only essential BattleManager status messages
- **No PDC/FireControl debug** - Remove all existing debug print statements
- **Professional formatting** - Battle report should be the primary console output

### Collision Deduplication
- **Frame-based deduplication** - Prevent multiple collision reports in same frame
- **Consistent collision keys** - Handle entity order independence
- **Race condition prevention** - EntityManager collision authority with safeguards
- **Simultaneous hit handling** - Multiple bullets hitting same torpedo handled correctly

---

## New System Architecture

### 1. BattleManager (New)
**Location**: `Scripts/Systems/BattleManager.gd`
**Responsibilities**: Battle orchestration and post-battle analysis

#### Core Functions:
- **Battle Lifecycle**: Start/end battle detection and control
- **System Coordination**: Tell TorpedoLauncher when to fire
- **Post-Battle Analysis**: Read EntityManager data and generate reports
- **Battle State**: Track battle phases (pre-battle, active, post-battle)

#### Battle Detection Logic:
```gdscript
# Battle Start: First torpedo registered in EntityManager
# Battle End: No torpedoes exist for 3+ seconds
# Analysis Trigger: Battle end confirmed
```

#### Key Methods:
- `start_battle()` - Initialize battle state, notify systems
- `end_battle()` - Finalize battle, trigger analysis
- `analyze_battle_data()` - Process EntityManager events into report
- `generate_battle_report()` - Create comprehensive battle statistics
- `print_clean_battle_report()` - Output final analysis to console (clean, minimal debug)

---

### 2. EntityManager (Enhanced)
**Location**: `Scripts/Managers/EntityManager.gd`
**Responsibilities**: Entity lifecycle + event recording + collision handling

#### New Core Functions:
- **Event Recording**: Log all entity births/deaths/collisions
- **Collision Authority**: Handle collision-based destruction
- **Battle Data**: Maintain arrays of battle events for BattleManager
- **Data Integrity**: Ensure no double-destruction or lost events

#### Event Data Structure:
```gdscript
var battle_events: Array = []
var entity_registry: Dictionary = {}

# Event types recorded:
{
    "type": "entity_registered|entity_destroyed|collision",
    "timestamp": float,
    "entity_id": string,
    "entity_type": string,
    "faction": string,
    "position": Vector2,
    "source_pdc": string,  # For bullets only
    "collision_partner": string,  # For collisions only
    "destruction_reason": string  # "collision|out_of_bounds|battle_end"
}
```

#### Enhanced Registration:
- **Bullets must include source PDC**: `register_entity(bullet, "pdc_bullet", faction, source_pdc_id)`
- **All entities get lifecycle tracking**: Birth → Updates → Death
- **Collision detection integration**: Replace direct destruction with EntityManager authority

#### Key New Methods:
- `report_collision(entity1_id, entity2_id, position)` - Handle collision destruction with duplicate prevention
- `get_battle_data()` - Return event arrays to BattleManager
- `clear_battle_data()` - Reset for new battle
- `destroy_entity_safe(entity_id, reason)` - Prevent double-destruction

#### Collision Deduplication System:
```gdscript
var pending_collisions: Dictionary = {}  # entity_id -> frame_number
var current_frame: int = 0

func report_collision(entity1_id: String, entity2_id: String, position: Vector2):
    # Prevent duplicate collision reports in same frame
    var collision_key = get_collision_key(entity1_id, entity2_id)
    
    if pending_collisions.has(collision_key) and pending_collisions[collision_key] == current_frame:
        return  # Already processed this collision this frame
    
    pending_collisions[collision_key] = current_frame
    # Process collision normally...

func get_collision_key(id1: String, id2: String) -> String:
    # Create consistent key regardless of order
    if id1 < id2:
        return id1 + "_" + id2
    else:
        return id2 + "_" + id1
```

---

### 3. Collision Detection Refactor
**Current Problem**: Entities destroy each other directly, causing race conditions
**New Solution**: Entities report collisions to EntityManager

#### PDCBullet.gd Changes:
```gdscript
# OLD (problematic):
func _on_area_entered(area: Area2D):
    area.queue_free()  # Direct destruction
    queue_free()

# NEW (safe):
func _on_area_entered(area: Area2D):
    var entity_manager = get_node("/root/EntityManager")
    entity_manager.report_collision(entity_id, area.entity_id, global_position)
    # EntityManager handles all destruction
```

#### Torpedo.gd Changes:
```gdscript
# Ship collision detection also goes through EntityManager
func _on_area_entered(area: Area2D):
    if area.is_in_group("ships"):
        var entity_manager = get_node("/root/EntityManager")
        entity_manager.report_collision(entity_id, area.entity_id, global_position)
```

---

### 4. System Simplification

#### PDCSystem.gd (Simplified)
**Remove All Battle Tracking**:
- ~~`var targets_hit: int`~~
- ~~`var rounds_fired: int`~~
- ~~`func _on_bullet_hit()`~~
- ~~`func get_battle_stats()`~~
- ~~Signal connections for hit tracking~~

**Enhanced Bullet Creation**:
```gdscript
func fire_bullet():
    var bullet = bullet_scene.instantiate()
    # NEW: Pass PDC ID to EntityManager during registration
    bullet.source_pdc_id = pdc_id
    # EntityManager will know this bullet came from this PDC
```

#### FireControlManager.gd (Cleaned)
**Remove All Battle Analysis**:
- ~~`var battle_stats: Dictionary`~~
- ~~`var intercept_log: Array`~~
- ~~`func print_comprehensive_battle_summary()`~~
- ~~`func report_successful_intercept()`~~
- ~~All battle report generation code~~

**Keep Only Fire Control**:
- Target assignment logic
- PDC coordination
- Firing solutions
- Target tracking for tactical purposes

#### TorpedoLauncher.gd (Interface Addition)
**Add BattleManager Interface**:
```gdscript
func start_battle_firing():
    auto_launch_enabled = true
    
func stop_battle_firing():
    auto_launch_enabled = false
```

---

### 5. BattleManager Analysis Logic

#### Data Processing Flow:
1. **Get Events**: `var events = EntityManager.get_battle_data()`
2. **Parse Lifecycle**: Track entity births/deaths
3. **Analyze Collisions**: Match bullets to torpedoes via collision events
4. **Calculate Statistics**: PDC effectiveness, intercept rates, distances
5. **Generate Report**: Format comprehensive battle analysis

#### Key Analytics:
```gdscript
# PDC Performance Analysis
func analyze_pdc_performance(events: Array) -> Dictionary:
    var pdc_stats = {}
    for event in events:
        if event.type == "entity_registered" and event.entity_type == "pdc_bullet":
            pdc_stats[event.source_pdc].bullets_fired += 1
        elif event.type == "collision" and involves_pdc_bullet(event):
            pdc_stats[get_bullet_source(event)].hits += 1

# Torpedo Fate Analysis  
func analyze_torpedo_outcomes(events: Array) -> Dictionary:
    var outcomes = {"intercepted": 0, "ship_hits": 0}
    for torpedo_id in get_all_torpedoes(events):
        if was_intercepted(torpedo_id, events):
            outcomes.intercepted += 1
        else:
            outcomes.ship_hits += 1
```

---

## Implementation Plan

### Phase 1: EntityManager Enhancement
1. Add event recording arrays and collision handling
2. Enhance entity registration to include source_pdc for bullets
3. Implement safe collision destruction system
4. Test with existing battle system still active

### Phase 2: Collision System Refactor
1. Modify PDCBullet.gd and Torpedo.gd collision detection
2. Route all collision destruction through EntityManager
3. Verify no double-destruction bugs
4. Test collision logging accuracy

### Phase 3: System Cleanup
1. Strip battle tracking from PDCSystem.gd
2. Remove battle analysis from FireControlManager.gd  
3. Clean up signal chains and statistics code
4. Verify core combat systems still work

### Phase 4: BattleManager Creation
1. Create BattleManager script with orchestration logic
2. Implement battle start/end detection
3. Add TorpedoLauncher interface for battle control
4. Implement collision deduplication system
5. Test battle lifecycle management

### Phase 5: Analysis Implementation
1. Implement data parsing and analysis algorithms
2. Create battle report generation system
3. Add clean console output formatting (minimal debug)
4. Test analysis accuracy against known scenarios
5. Polish report formatting and statistics

### Phase 6: Integration Testing
1. Full system integration testing
2. Performance testing with 100+ torpedoes
3. Edge case testing (simultaneous collisions, etc.)
4. Battle report accuracy verification

---

## Expected Benefits

### Immediate Benefits:
- **Eliminates signal chain bugs** - No more PDC hit counting issues
- **Prevents race conditions** - EntityManager controls all destruction
- **Single source of truth** - All battle data comes from one place
- **Simplified debugging** - Clear data flow and responsibilities

### Long-term Benefits:
- **Perfect battle accuracy** - EntityManager sees everything that happens
- **Easy feature additions** - Want new statistics? Just analyze existing data
- **Performance optimization** - No duplicate tracking across systems
- **Maintainable code** - Each system has one clear purpose

### Risk Mitigation:
- **No data loss** - EntityManager buffers all events
- **No corruption** - Single authority prevents conflicts  
- **Easy rollback** - Can implement incrementally
- **Performance safety** - In-memory arrays, no file I/O during battle

---

## Success Metrics

### Functional Success:
- ✅ Battle reports show accurate PDC hit counts
- ✅ All torpedo fates correctly classified (intercept vs ship hit)
- ✅ No "torpedoes hitting ships from 8km away" anomalies
- ✅ Simultaneous collision handling works correctly

### Performance Success:
- ✅ No lag during 100+ torpedo battles
- ✅ Clean battle start/end transitions
- ✅ Memory usage remains stable across multiple battles

### Code Quality Success:
- ✅ Each system has single, clear responsibility
- ✅ No cross-system dependencies for battle tracking
- ✅ Easy to understand data flow
- ✅ Debuggable event trail for any battle scenario