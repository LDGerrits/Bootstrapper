# Bootstrapper

A lightweight bootstrapper for Roblox. Find modules, ensure predictable execution order, and route RunService events with memory profiling included.

## Features

* **Predictable Flow:** Use `loadSequence` or `sort` to guarantee your modules initialize exactly when you expect.
* **Memory Profiling:** Automatically assigns `debug.setmemorycategory` to every module's thread and RunService loop.
* **Isolated Startup:** Errors in one module won't stop the rest of your game from loading (unless you want to).
* **Event Routing:** Connect modules directly to engine events or custom signals with selective binding and uniform cleanup.

## Installation

### Wally

The package name + version is

```
ldgerrits/bootstrapper@^1.0.11
```

## Usage

### 1. Find & Load Modules
Load your modules and determine whether Bootstrapper should inject `self`.
```lua
local Bootstrapper = require(ReplicatedStorage.Packages.Bootstrapper)

local success, services, errors = Bootstrapper.loadDescendants(ReplicatedStorage.Shared.Services, {
    predicate = Bootstrapper.matchesName("Service$"),
    self = true -- Default
})
```

### 2. Lifecycles

Execute methods across all loaded modules.
```Lua
-- Block thread until all 'init' methods finish
Bootstrapper.callSync(services, "init", gameState)

-- Fire 'start' methods and move on immediately
Bootstrapper.callAsync(services, "start")
```

### 3. Events

Route engine and game events directly to your module methods.
```Lua
-- Hook into RunService
local cleanupHeartbeat = Bootstrapper.heartbeat(services, "onHeartbeat")

-- Only modules with 'onStateChanged' will connect to GameState.Changed
local cleanupStateChanged = Bootstrapper.bind(services, GameState.Changed, "onStateChanged")

-- Later, safely disconnect everything
cleanupHeartbeat()
cleanupStateChanged()
```
