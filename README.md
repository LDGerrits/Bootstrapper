# Bootstrapper

A lightweight and unopinionated lifecycle manager for Roblox. Find and load modules, run their functions, and bind them to RunService without the boilerplate.

## Features

* **Zero Boilerplate:** Load entire folders of modules and connect them to events in three lines of code.
* **Safe Booting:** Syntax errors or crashing functions in one module won't stop the rest of your game from loading.
* **Deterministic Order:** Use `loadSequence` or `getSorted` to guarantee strict order.
* **Memory Profiling:** Automatically assigns `debug.setmemorycategory` to every module's thread and RunService loop.
* **RunService Integration:** Binds directly to RunService events, fully supporting native priorities and frequencies.

## Installation

### Wally

The package name + version is

```
ldgerrits/bootstrapper@^1.0.0
```

## Usage

### 1. Find & Load Modules
Discover your modules and determine how they handle self injection.
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

## API

### Discovery

`Bootstrapper.matchesName(matchName: string) -> Predicate`
Creates a name-matching filter.

`Bootstrapper.loadChildren(parent: Instance, options: Options?) -> (boolean, Modules, {[ModuleScript]: string})`
Requires direct child ModuleScripts. Returns a success boolean, the loaded modules, and a map of errors.

`Bootstrapper.loadDescendants(parent: Instance, options: Options?) -> (boolean, Modules, {[ModuleScript]: string})`
Recursively requires all descendant ModuleScripts.

`Bootstrapper.loadSequence(sequence: {ModuleScript}, options: Options?) -> (boolean, Modules, {[ModuleScript]: string})`
Requires modules in a guaranteed execution order.

`Bootstrapper.getSorted(modules: Modules, sortFunction: function?) -> {any}`
Converts a dictionary into an alphabetically sorted array.

---

### Execution

`Bootstrapper.callSync(modules: Modules, methodName: string, ...any) -> (boolean, Modules, {[any]: string})`
*Yields.* Invokes the method concurrently and yields until finished. Returns a success boolean, the surviving modules, and a crash map.

`Bootstrapper.callAsync(modules: Modules, methodName: string, ...any): ()`
Invokes the method concurrently and asynchronously via `task.spawn`.

---

### Events
*All methods in this section return a **Cleanup** function `() -> ()`.*

`Bootstrapper.bind(modules: Modules, source: EventSource, methodName: string): Cleanup`
Binds a method to a Signal (Roblox/Custom) or a Subscription Function. Returns a cleanup function for all connections.

`Bootstrapper.heartbeat(modules: Modules, methodName: string): Cleanup`
Binds to `RunService.Heartbeat`.

`Bootstrapper.renderStepped(modules: Modules, methodName: string, priority: number?): Cleanup`
Binds to `RunService.RenderStepped`. Uses `BindToRenderStep` if priority is provided.

`Bootstrapper.preSimulation(modules: Modules, methodName: string, frequency: Enum.StepFrequency?): Cleanup`
Binds to `RunService.PreSimulation`. Uses `BindToSimulation` if frequency is provided.

`Bootstrapper.postSimulation(modules: Modules, methodName: string): Cleanup`
Binds to `RunService.PostSimulation`.

`Bootstrapper.preAnimation(modules: Modules, methodName: string): Cleanup`
Binds to `RunService.PreAnimation`.

`Bootstrapper.preRender(modules: Modules, methodName: string, priority: number?): Cleanup`
Binds to `RunService.PreRender`. Uses `BindToRenderStep` if priority is provided.
