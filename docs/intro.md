---
sidebar_position: 1
---

# Bootstrapper

A lightweight, deterministic bootstrapper for Roblox. Find modules, control the execution flow, and bind to (RunService) events with memory tracking.

## Features

* **Predictable Order:** Set a specific execution flow for your modules.
* **Event Binding:** Connect modules directly to RunService events or custom signals.
* **Memory Profiling:** Automatically assigns `debug.setmemorycategory` to every module's thread and RunService loop.

## Installation

### Wally

Add this to your wally.toml:

```
ldgerrits/bootstrapper@^1.0.12
```

## Usage

### 1. Finding & Loading Modules

Load modules from a folder. Bootstrapper automatically requires them and returns a **deterministically sorted array** (alphabetical by Name), ensuring your game starts the same way every time.

```lua
local Bootstrapper = require(path.to.Bootstrapper)

local services, errors = Bootstrapper.loadDescendants(path.to.Services, Bootstrapper.byName('Service$'))
```

### 2. Manual Sequences

You can use `loadSequence` to define a strict, custom order using raw ModuleScript references. This sequence can be stored and reused for all lifecycle stages.

```Lua
local services, errors = Bootstrapper.loadSequence({
    path.to.DataService,
    path.to.PlayerService,
    path.to.AssetService,
})

-- Use the resulting services array for everything else
Bootstrapper.callSync(services, 'init')
Bootstrapper.bindToHeartbeat(services, 'onHeartbeat')
```

### 3. Lazy Resolution

You don't have to call a 'load' function. You can also just pass an array of ModuleScripts directly to events, and the Bootstrapper will handle the require() and memory profiling for you automatically.

```Lua
-- This works even if the modules haven't been required yet
Bootstrapper.bindToHeartbeat({
    path.to.CombatService,
    path.to.VFXService,
}, 'onUpdate')
```

### 4. Lifecycles

Trigger methods across your modules. `callSync` yields the current thread until all modules finish, while `callAsync` fires them in background threads.

```Lua
-- Yields until every module's `init` function returns
-- Only modules that successfully finish 'init' are returned
local services, errors = Bootstrapper.callSync(services, 'init')

-- Fire 'start' methods without yielding
-- You can pass arguments like 'gameData' here!
Bootstrapper.callAsync(services, 'start', gameData)
```

### 5. Event Binding

Route `RunService` events or signals directly to module methods. All binding functions follow the same signature: `(modules, methodName, [context])`.

```Lua
local cleanupHeartbeat = Bootstrapper.bindToHeartbeat(services, 'onHeartbeat')

local cleanupRenderStep = Bootstrapper.bindToRenderStep(services, 'onRender', Enum.RenderPriority.Last.Value)

local cleanupGameStateChanged = Bootstrapper.bindTo(services, 'onGameState', GameState.Changed)

-- Disconnect everything when they are no longer needed
cleanupHeartbeat()
cleanupRenderStep()
cleanupGameStateChanged()
```
