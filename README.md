# Bootstrapper

A lightweight, deterministic bootstrapper for Roblox. Find modules, control the execution flow, and bind to (RunService) events with memory tracking.

## Features

* **Predictable Flow:** Load modules in a deterministically sorted order (alphabetical) or define a strict manual sequence.
* **Event Binding:** Connect modules directly to RunService events or custom signals.
* **Method Call Syntax:** Use standard Lua syntax (`.` vs `:`) in your method names to explicitly call static functions or object methods.
* **Memory Profiling:** Automatically assigns `debug.setmemorycategory` to every module's thread and RunService loop.

## Installation

### Wally

Add this to your wally.toml:

```
ldgerrits/bootstrapper@^1.0.14
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
Bootstrapper.callSync(services, '.init')
```

### 3. Dot vs. Colon Notation
When passing a method name to any Bootstrapper function, you can dictate how the function is executed:

- `'init'` (Default): Calls as an object method. `module:init()`

- `':init'` (Explicit OOP): Calls as an object method. `module:init()`

- `'.init'` (Static): Calls as a static function.` module.init()`

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
}, 'onUpdate')
```

### 5. Lifecycles

Trigger methods across your modules. `callSync` yields the current thread until all modules finish, while `callAsync` fires them in background threads.

```Lua
-- Yields until every module's `.init` function returns
-- Only modules that successfully finish '.init' are returned
local services, errors = Bootstrapper.callSync(services, '.init')

-- Fire '.start' methods without yielding
-- You can pass arguments like 'gameData' here!
Bootstrapper.callAsync(services, '.start', gameData)
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
