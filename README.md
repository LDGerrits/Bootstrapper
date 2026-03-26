# Bootstrapper

A lightweight and unopinionated lifecycle manager for Roblox. Find and load modules, run their functions, and bind them to RunService without the boilerplate.

## Features

**Zero Boilerplate:** Load entire folders of modules and connect them to events in three lines of code.

**Safe Booting:** Syntax errors or crashing functions in one module won't stop the rest of your game from loading.

**Deterministic Order:** Use `loadSequence` or `getSorted` to guarantee order of operations.

**Memory Profiling:** Automatically assigns `debug.setmemorycategory` to every module's thread and RunService events.

**RunService Integration:** Binds directly to RunService events, fully supporting native priorities and frequencies.

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
local Bootstrapper = require(path.to.Bootstrapper)

local services, loadErrors = Bootstrapper.loadDescendants(script.Parent.Services, {
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

-- Bind to a standard Roblox Signal
local cleanupPlayerAdded = Bootstrapper.bind(services, Players.PlayerAdded, "onPlayerJoined")

-- Later, safely disconnect everything (e.g., when a round ends)
cleanupHeartbeat()
cleanupPlayerAdded()
```

## API

### Discovery

`Bootstrapper.matchesName(matchName: string) -> Predicate`
Creates a name-matching filter to be used as predicate in options.

`Bootstrapper.loadChildren(parent: Instance, options: { predicate: Predicate?, self: boolean? }? ) -> Modules`
Requires all direct child ModuleScripts. Use `{ self = false }` in options to treat them as static modules.

`Bootstrapper.loadDescendants(parent: Instance, options: { predicate: Predicate?, self: boolean? }? ) -> Modules`
Recursively requires all descendant ModuleScripts. Use `{ self = false }` to treat them as static modules.

`Bootstrapper.loadSequence(parent: Instance?, sequence: {string | ModuleScript}, options: Options?) -> (Modules, {[ModuleScript]: string})`
Requires specific modules in a guaranteed execution order. Returns an ordered array of successful modules and a map of errors.

`Bootstrapper.getSorted(modules: Modules, sortFunction: function?) -> {any}`
Converts a module dictionary into a deterministic array. Defaults to alphabetical sort by module name.

`Bootstrapper.combine(...: Modules) -> Modules`
Merges multiple module collections into one.

---

### Execution

`Bootstrapper.callSync(modules: Modules, methodName: string, ...any) -> (Modules, {[any]: string})`
*Yields.* Invokes the method concurrently on all modules and yields the calling thread until all have finished. Returns a table of successful modules and a map of modules that crashed. Supports varargs.

`Bootstrapper.callAsync(modules: Modules, methodName: string, ...any): ()`
Invokes the method on all modules asynchronously via `task.spawn`. Supports varargs.

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

`Bootstrapper.stepped(modules: Modules, methodName: string): Cleanup`
Binds to `RunService.Stepped`.
