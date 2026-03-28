---
sidebar_position: 1
---

# Bootstrapper

#### 100% Explicit Control Flow — Agnostic Module Loader & Scheduler

Bootstrapper is a lightweight, agnostic module loader and scheduler for Roblox. Instead of letting individual scripts manage their own event connections, it enforces a deterministic order of operations across your entire codebase, letting you decide exactly what runs, and in what order, every single frame.

## Why Bootstrapper?

As Roblox projects scale, developers often fall into the trap of decentralized execution. Every module, controller or service connects to `RunService` independently. Before long, you have dozens of scripts updating independently every frame. Without strict control over whether your `InputSystem` runs before or after your `CharacterController`, you inevitably run into state bugs, race conditions, and one-frame delays.

Bootstrapper solves this by treating execution flow as a single, managed pipeline. By organizing your modules into simple arrays and updating them in a strict sequence, you completely eliminate unpredictable load orders and execution desyncs. Bootstrapper makes sure things happen exactly when you tell them to, and doesn't care if you write OOP, functional, or procedural code.

## Features

* **Deterministic Execution:** Load modules alphabetically or provide a strict manual sequence. Your game will start exactly the same way every single time.
* **Centralized Scheduler:** Iterate over your modules and fire their updates synchronously.
* **Luau Method Syntax:** Use standard dot or colon notation (`.` or `:`) in your string arguments to explicitly call static functions or inject `self` for object methods.
* **Flexible Event Binding:** Hook a sequence of modules directly to `RunService` events, `RBXScriptSignals`, or custom Signal objects.
* **Automatic Memory Profiling:** Automatically assigns `debug.setmemorycategory` to every module's thread and `RunService` connection so your `MicroProfiler` is readable.
* **Lazy Require:** Pass raw `ModuleScript` instances directly as argument. Bootstrapper will automatically require and cache them for you.

## Installation

### Wally

Add this to your wally.toml:

```
ldgerrits/bootstrapper@^1.0.17
```

## Quick Start
```lua
local Bootstrapper = require(packages.Bootstrapper)

-- Strict boot sequence (manual order for core systems)
local bootSequence = { path.to.DataService, path.to.PlayerService, path.to.ZoneService }
Bootstrapper.run(bootSequence, ':init') -- injects self
Bootstrapper.runAsync(bootSequence, ':start') -- injects self

-- Automatic discovery (A-Z Sorting)
local systems = Bootstrapper.loadChildren(path.to.Systems, Bootstrapper.byName('System$'))

-- Execution choice
-- Use 'run' for a strict A-Z sequence, or 'runParallel' if not
Bootstrapper.run(systems, '.init') -- does NOT inject self
Bootstrapper.runParallel(systems, '.start') -- does NOT inject self

-- Deterministic runtime (only binds modules with 'onUpdate')
-- Maintains alphabetical execution every frame with auto-memory profiling.
Bootstrapper.bindToHeartbeat(systems, '.onUpdate') -- does NOT inject self
```

## Usage

### 1. Finding & Loading Modules

Load modules from a folder. Bootstrapper automatically requires them and returns a deterministically sorted array (alphabetical by Name), ensuring your game starts the same way every time.

```lua
local Bootstrapper = require(path.to.Bootstrapper)

local services, errors = Bootstrapper.loadDescendants(path.to.Services, Bootstrapper.byName('Service$'))
```

### 2. Manual Sequences

You can use `loadSequence` to define a manual order using an array `ModuleScript` instances. This sequence can be stored and reused for all lifecycle stages.

```Lua
local services, errors = Bootstrapper.loadSequence({
    path.to.DataService,
    path.to.PlayerService,
    path.to.AssetService,
})

-- Use the resulting services array for everything else
Bootstrapper.run(services, '.init')
```

### 3. Dot vs. Colon Notation
When passing a method name to any Bootstrapper function, you can dictate how the function is executed:

- `'methodName'` or `':methodName'`: Calls as an object method. `module:methodName()`

- `'.methodName'` (Static): Calls as a static function.` module.methodName()`

```lua
-- Injects 'self' into every module's 'onUpdate' method
Bootstrapper.bindToHeartbeat(services, ':onUpdate')

-- Calls 'tick' statically, without passing the module table
Bootstrapper.bindToHeartbeat(services, '.tick')
```

### 4. Lazy Resolution

You don't have to call a 'load' function. You can also just pass an array of ModuleScripts directly to events, and the Bootstrapper will handle the require() and memory profiling for you automatically.

```Lua
-- This works even if the modules haven't been required yet
Bootstrapper.bindToHeartbeat({
    path.to.CombatService,
    path.to.VFXService,
}, '.onUpdate')
```

### 5. Execution Flow

Trigger methods across your modules. `run` yields the current thread until all modules finish, while `parallel` fires them in background threads.

```Lua
-- Sequential & Blocking
-- Yields until every module's '.init' finishes in order.
-- Returns an array of successful modules and a map of errors.
local loaded, errors = Bootstrapper.run(services, 'init')

-- Sequential & Non-blocking
-- Executes the sequence in the background without yielding the caller.
-- Maintains your deterministic order of operations.
Bootstrapper.runAsync(services, 'postInit')

-- Parallel & Non-blocking
-- Fires all methods simultaneously for maximum speed.
-- Best for independent tasks where execution order doesn't matter.
Bootstrapper.runParallel(services, 'start', gameData)
```

### 6. Event Binding

Route `RunService` events or signals directly to module methods. All binding functions follow the same signature: `(modules, methodName, [context])`.

```Lua
local cleanupHeartbeat = Bootstrapper.bindToHeartbeat(services, 'onHeartbeat')

local cleanupRenderStep = Bootstrapper.bindToRenderStep(services, 'onRender', Enum.RenderPriority.Last.Value)

local cleanupGameState = Bootstrapper.bindTo(services, 'onGameState', GameState.Changed)

-- Disconnect everything when they are no longer needed
cleanupHeartbeat()
cleanupRenderStep()
cleanupGameState()
```
