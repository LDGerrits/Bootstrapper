--!strict
--!nolint LocalUnused
--!nolint LocalShadow

local RunService = game:GetService('RunService')

export type Modules = { [string]: any }
export type Predicate = (module: ModuleScript) -> boolean

export type Signal =
	{ Connect: (any, (...any) -> ...any) -> any }
	| { connect: (any, (...any) -> ...any) -> any }
	| RBXScriptSignal

export type EventSource = Signal | ((callback: (...any) -> ()) -> Task)
export type Cleanup = () -> ()

export type Task =
	Instance
	| RBXScriptConnection
	| () -> ()
	| { destroy: (unknown) -> () }
	| { Destroy: (unknown) -> () }
	| { disconnect: (unknown) -> () }
	| { Disconnect: (unknown) -> () }
	| { Task }

--[=[
	@class Bootstrapper
	A lightweight, zero-dependency utility for discovering modules, managing lifecycles, and natively binding to events/loops.
]=]
local Bootstrapper = {}

local injectSelfRegistry = setmetatable({}, { __mode = 'k' })

local function shouldInjectSelf(module: any): boolean
	local registered = injectSelfRegistry[module]
	if registered ~= nil then
		return registered
	end
	return true
end

local function doCleanup(task: Task): ()
	if typeof(task) == 'Instance' then
		task:Destroy()
	elseif typeof(task) == 'RBXScriptConnection' then
		task:Disconnect()
	elseif typeof(task) == 'function' then
		task()
	elseif typeof(task) == 'table' then
		local taskTable = (task :: any) :: {
			Destroy: (...unknown) -> ...unknown?,
			destroy: (...unknown) -> ...unknown?,
			Disconnect: (...unknown) -> ...unknown?,
			disconnect: (...unknown) -> ...unknown?,
		}

		if typeof(taskTable.destroy) == 'function' then
			local t = (taskTable :: any) :: { destroy: (...unknown) -> ...unknown }
			t:destroy()
		elseif typeof(taskTable.Destroy) == 'function' then
			local t = (taskTable :: any) :: { Destroy: (...unknown) -> ...unknown }
			t:Destroy()
		elseif typeof(taskTable.Disconnect) == 'function' then
			local t = (taskTable :: any) :: { Disconnect: (...unknown) -> ...unknown }
			t:Disconnect()
		elseif typeof(taskTable.disconnect) == 'function' then
			local t = (taskTable :: any) :: { disconnect: (...unknown) -> ...unknown }
			t:disconnect()
		end
	end
end

local function bindToRunService(
	modules: Modules,
	eventName: string,
	methodName: string,
	override: (number | EnumItem)?
): Cleanup
	local tasks: { Task } = {}

	for name, module in modules do
		local method = module[methodName]
		if type(method) ~= 'function' then
			continue
		end

		local function run(...)
			local useSelf = shouldInjectSelf(module)
			if useSelf then
				method(module, ...)
			else
				method(...)
			end
		end

		if (eventName == 'RenderStepped' or eventName == 'PreRender') and RunService:IsClient() then
			if type(override) == 'number' then
				local bindName = `{name}_{methodName}`
				RunService:BindToRenderStep(bindName, override, run)
				table.insert(tasks, function()
					RunService:UnbindFromRenderStep(bindName)
				end)
			else
				table.insert(tasks, RunService.PreRender:Connect(run))
			end
		elseif eventName == 'PreSimulation' and RunService.BindToSimulation then
			if typeof(override) == 'EnumItem' and (override :: EnumItem).EnumType == Enum.StepFrequency then
				table.insert(tasks, (RunService :: any):BindToSimulation(run, override))
			else
				table.insert(tasks, RunService.PreSimulation:Connect(run))
			end
		else
			local event = (RunService :: any)[eventName]
			if event then
				table.insert(tasks, event:Connect(run))
			end
		end
	end

	return function()
		for _, task in tasks do
			doCleanup(task)
		end
	end
end

--[=[
	Creates a predicate function that matches a module's name against a string.
	@function matchesName
	@within Bootstrapper
	@param matchName string -- The string pattern to match against the module's name.
	@return Predicate
]=]
function Bootstrapper.matchesName(matchName: string): Predicate
	return function(moduleScript: ModuleScript)
		return moduleScript.Name:match(matchName) ~= nil
	end
end

--[=[
	Requires all direct child ModuleScripts within a given parent.
	@function loadChildren
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param options { predicate: Predicate?, useSelf: boolean? }? -- Options for filtering and self-injection.
	@return Modules
]=]
function Bootstrapper.loadChildren(
	parent: Instance,
	options: {
		predicate: Predicate?,
		self: boolean?,
	}?
): Modules
	local modules = {}
	local predicate = if options then options.predicate else nil
	local shouldInject = not options or options.self ~= false

	for _, child in parent:GetChildren() do
		if child:IsA('ModuleScript') then
			if predicate and not predicate(child) then
				continue
			end
			local req = require(child) :: any
			if type(req) == 'table' then
				injectSelfRegistry[req] = shouldInject
			end
			modules[child.Name] = req
		end
	end
	return modules
end

--[=[
	Requires all descendant ModuleScripts within a given parent.
	@function loadDescendants
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param options { predicate: Predicate?, useSelf: boolean? }? -- Options for filtering and self-injection.
	@return Modules
]=]
function Bootstrapper.loadDescendants(
	parent: Instance,
	options: {
		predicate: Predicate?,
		self: boolean?,
	}?
): Modules
	local modules = {}
	local predicate = if options then options.predicate else nil
	local shouldInject = not options or options.self ~= false

	for _, descendant in parent:GetDescendants() do
		if descendant:IsA('ModuleScript') then
			if predicate and not predicate(descendant) then
				continue
			end
			local req = require(descendant) :: any
			if type(req) == 'table' then
				injectSelfRegistry[req] = shouldInject
			end
			modules[descendant.Name] = req
		end
	end
	return modules
end

--[=[
	Executes a method on all modules and yields the calling thread until all modules have finished.
	@yields
	@function callSync
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param methodName string -- The name of the function to call on the modules.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.callSync(modules: Modules, methodName: string, ...: any): ()
	local mainThread = coroutine.running()
	local total, done = 0, 0

	for _, module in modules do
		if type(module[methodName]) == 'function' then
			total += 1
		end
	end

	if total == 0 then
		return 0, 0
	end

	for name, module in modules do
		local fn = module[methodName]
		if type(fn) == 'function' then
			local useSelf = shouldInjectSelf(module)

			task.spawn(function(...)
				debug.setmemorycategory(name)

				local success, err = xpcall(function(...)
					if useSelf then
						fn(module, ...)
					else
						fn(...)
					end
				end, debug.traceback, ...)

				if not success then
					warn(`[Bootstrapper] Error in {name}:{methodName} - {err}`)
				end

				done += 1
				if done == total then
					task.spawn(mainThread)
				end
			end, ...)
		end
	end

	coroutine.yield()
end

--[=[
	Executes a method on all modules asynchronously using `task.spawn` (Fire and forget).
	@function callAsync
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param methodName string -- The name of the function to call on the modules.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.callAsync(modules: Modules, methodName: string, ...: any): ()
	for name, module in modules do
		local fn = module[methodName]
		if type(fn) == 'function' then
			local useSelf = shouldInjectSelf(module)

			local function wrapper(...)
				debug.setmemorycategory(name)
				if useSelf then
					fn(module, ...)
				else
					fn(...)
				end
			end
			task.spawn(wrapper, ...)
		end
	end
end

--[=[
	Binds a method across all modules to a Signal, Custom Signal, or Callback Subscription.
	@function bind
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param source EventSource -- A Signal (e.g., PlayerAdded) or a subscription function.
	@param methodName string -- The name of the function to trigger.
	@return Cleanup -- A uniform cleanup function to disconnect the event.
]=]
function Bootstrapper.bind(modules: Modules, source: EventSource, methodName: string): Cleanup
	local tasks: { Task } = {}

	if type(source) == 'function' then
		for _, module in modules do
			local fn = module[methodName]
			if type(fn) == 'function' then
				local task = source(function(...)
					local useSelf = shouldInjectSelf(module)
					if useSelf then
						task.spawn(fn, module, ...)
					else
						task.spawn(fn, ...)
					end
				end)
				table.insert(tasks, task)
			end
		end
	else
		local connectMethod = (source :: any).Connect or (source :: any).connect
		local connection = connectMethod(source, function(...)
			for _, module in modules do
				local fn = module[methodName]
				if type(fn) == 'function' then
					local useSelf = shouldInjectSelf(module)
					if useSelf then
						task.spawn(fn, module, ...)
					else
						task.spawn(fn, ...)
					end
				end
			end
		end)
		table.insert(tasks, connection)
	end

	return function()
		for _, task in tasks do
			doCleanup(task)
		end
	end
end

--[=[
	Hooks a specified method in all modules to `RunService.Heartbeat`.
	@function heartbeat
	@within Bootstrapper
	@param modules Modules
	@param methodName string
	@return Cleanup
]=]
function Bootstrapper.heartbeat(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'Heartbeat', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.RenderStepped` (Client-side only).
	@function renderStepped
	@within Bootstrapper
	@param modules Modules
	@param methodName string
	@param priority number?
	@return Cleanup
]=]
function Bootstrapper.renderStepped(modules: Modules, methodName: string, priority: number?): Cleanup
	return bindToRunService(modules, 'RenderStepped', methodName, priority)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreSimulation`. 
	@function preSimulation
	@within Bootstrapper
	@param modules Modules
	@param methodName string
	@param frequency Enum.StepFrequency?
	@return Cleanup
]=]
function Bootstrapper.preSimulation(modules: Modules, methodName: string, frequency: Enum.StepFrequency?): Cleanup
	return bindToRunService(modules, 'PreSimulation', methodName, frequency)
end

--[=[
	Hooks a specified method in all modules to `RunService.PostSimulation`.
	@function postSimulation
	@within Bootstrapper
	@param modules Modules
	@param methodName string
	@return Cleanup
]=]
function Bootstrapper.postSimulation(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'PostSimulation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreAnimation`.
	@function preAnimation
	@within Bootstrapper
	@param modules Modules
	@param methodName string
	@return Cleanup
]=]
function Bootstrapper.preAnimation(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'PreAnimation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreRender`.
	@function preRender
	@within Bootstrapper
	@param modules Modules
	@param methodName string
	@param priority number?
	@return Cleanup
]=]
function Bootstrapper.preRender(modules: Modules, methodName: string, priority: number?): Cleanup
	return bindToRunService(modules, 'PreRender', methodName, priority)
end

--[=[
	Hooks a specified method in all modules to `RunService.Stepped` (Legacy).
	@function stepped
	@within Bootstrapper
	@param modules Modules
	@param methodName string
	@return Cleanup
]=]
function Bootstrapper.stepped(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'Stepped', methodName)
end

return Bootstrapper
