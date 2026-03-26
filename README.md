# Bootstrapper

A minimalist and unopinionated bootstrapper for Roblox. Discover and require modules, manage lifecycles, and connect to (RunService) events.

## Features

* **Unopinionated:** No forced folder structures or naming conventions. You decide how your project is organized.
* **Universal Event Routing:** Binds seamlessly to `RBXScriptSignals`, Signal modules, subscription methods, and more.
* **Non-Invasive:** Your modules stay clean.

---

## Quick Start

### 1. Find & Load Modules
```lua
local Bootstrapper = require(path.to.Bootstrapper)

local services = Bootstrapper.loadDescendants(script.Parent.Services, {
    predicate = Bootstrapper.matchesName("Service$"),
    self = true -- Default
})
```

### 2. Lifecycles
```Lua
-- Block thread until all 'init' methods finish
Bootstrapper.callSync(services, "init", sharedConfig)

-- Fire 'start' methods and move on immediately
Bootstrapper.callAsync(services, "start")
```

### 3. Events
```Lua
-- Hook into RunService
local cleanupHeartbeat = Bootstrapper.heartbeat(services, "onHeartbeat")

-- Bind to a standard Roblox Signal
local cleanupPlayerAdded = Bootstrapper.bind(services, Players.PlayerAdded, "onPlayerJoined")

-- Later, safely disconnect everything (e.g., when a round ends)
cleanupHeartbeat()
cleanupPlayerAdded()
```

---

## API

### Discovery

`Bootstrapper.matchesName(matchName: string) -> Predicate`
Creates a name-matching filter to be used in the discovery options.

`Bootstrapper.loadChildren(parent: Instance, options: { predicate: Predicate?, self: boolean? }? ) -> Modules`
Requires all direct child ModuleScripts. Use `{ self = false }` in options to treat them as static modules.

`Bootstrapper.loadDescendants(parent: Instance, options: { predicate: Predicate?, self: boolean? }? ) -> Modules`
Recursively requires all descendant ModuleScripts. Use `{ self = false }` to treat them as static modules.

---

### Execution

`Bootstrapper.callSync(modules: Modules, methodName: string, ...any): ()`
*Yields.* Invokes the method on all modules concurrently and yields the calling thread until all have finished. Supports varargs.

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
