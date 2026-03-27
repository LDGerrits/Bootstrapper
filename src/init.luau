-- Bootstrapper v1.0.11 • LDGerrits
--!strict
--!nolint LocalUnused
--!nolint LocalShadow

local RunService = game:GetService('RunService')

local batchCounter = 0
local moduleNameRegistry = setmetatable({}, { __mode = 'k' })

export type LoadedModule = { [string]: any }
export type Modules = { [string]: LoadedModule } | { LoadedModule } | { ModuleScript }
export type Errors = { [string]: string }
export type Predicate = (module: ModuleScript) -> boolean

export type Signal =
	{ Connect: (any, (...any) -> ...any) -> any }
	| { connect: (any, (...any) -> ...any) -> any }
	| RBXScriptSignal

export type Event = Signal | ((callback: (...any) -> ()) -> Task)
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
	A lightweight bootstrapper for Roblox. 
	Find modules, ensure predictable execution order, 
	and route RunService events with memory profiling included.
]=]
local Bootstrapper = {}

local function nonFatalError(messageTemplate: string, trace: string?, ...: any)
	local messageText = string.format(messageTemplate, ...)
	messageText = `[Bootstrapper] {messageText}`

	if trace and trace ~= '' then
		messageText ..= `\n---- Stack trace ----\n{trace}`
	end

	local formattedString = messageText:gsub('\n', '\n    ')

	task.spawn(function()
		error(formattedString, 0)
	end)
end

local function getModuleName(module: any, fallbackKey: any): string
	if type(module) == 'table' then
		local registeredName = moduleNameRegistry[module]
		if registeredName then
			return registeredName
		end
	end
	return tostring(fallbackKey)
end

local function resolveModule(value: any, key: any, errors: Errors?): (any, string)
	if typeof(value) == 'Instance' and value:IsA('ModuleScript') then
		local success, result = pcall(require, value)
		if success then
			if type(result) == 'table' then
				moduleNameRegistry[result] = value.Name
			end
			return result, value.Name
		else
			local errName = value.Name
			local errMsg = tostring(result)
			if errors then
				errors[errName] = errMsg
			end
			nonFatalError("Failed to resolve '%s':\n%s", nil, errName, errMsg)
			return nil, errName
		end
	end
	return value, getModuleName(value, key)
end

local function loadModule(module: ModuleScript, services: { [string]: any }, errors: Errors?, predicate: Predicate?)
	if predicate and not predicate(module) then
		return
	end

	local success, result = pcall(require, module)
	if success then
		if type(result) == 'table' then
			moduleNameRegistry[result] = module.Name
		end
		services[module.Name] = result
	else
		if errors then
			errors[module.Name] = tostring(result)
		end
		nonFatalError("Failed to load '%s':\n%s", nil, module.Name, tostring(result))
	end
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

	local b_modules = {}
	local b_fns = {}
	local b_names = {}
	local count = 0

	for key, value in modules :: { [any]: any } do
		local module, actualName = resolveModule(value, key)
		if type(module) ~= 'table' then
			continue
		end

		local fn = module[methodName]
		if type(fn) == 'function' then
			count += 1
			b_modules[count] = module
			b_fns[count] = fn
			b_names[count] = actualName
		end
	end

	if count == 0 then
		return function() end
	end

	local function run(...)
		for i = 1, count do
			debug.setmemorycategory(b_names[i])
			b_fns[i](b_modules[i], ...)
		end
	end

	if (eventName == 'RenderStepped') and RunService:IsClient() then
		if type(override) == 'number' then
			batchCounter += 1
			local bindName = `Bootstrapper_RenderBatch_{batchCounter}_{methodName}`
			RunService:BindToRenderStep(bindName, override, run)
			table.insert(tasks, function()
				RunService:UnbindFromRenderStep(bindName)
			end)
		else
			table.insert(tasks, RunService.RenderStepped:Connect(run))
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
	@yields
	@function loadChildren
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param predicate: Predicate? -- Filter
	@return boolean, Modules, Errors -- (Success, Modules, Errors)
]=]
function Bootstrapper.loadChildren(parent: Instance, predicate: Predicate?): (boolean, Modules, Errors)
	local services: { [string]: any }, errors: Errors = {}, {}
	for _, child in parent:GetChildren() do
		if child:IsA('ModuleScript') then
			loadModule(child, services, errors, predicate)
		end
	end
	return next(errors) == nil, services, errors
end

--[=[
	Requires all descendant ModuleScripts within a given parent.
	@yields
	@function loadDescendants
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param predicate: Predicate? -- Filter
	@return boolean, Modules, Errors -- (Success, Modules, Errors)
]=]
function Bootstrapper.loadDescendants(parent: Instance, predicate: Predicate?): (boolean, Modules, Errors)
	local services: { [string]: any }, errors: Errors = {}, {}
	for _, descendant in parent:GetDescendants() do
		if descendant:IsA('ModuleScript') then
			loadModule(descendant, services, errors, predicate)
		end
	end
	return next(errors) == nil, services, errors
end

--[=[
	Requires specific modules in a guaranteed order.
	@yields
	@function loadSequence
	@within Bootstrapper
	@param sequence {ModuleScript} -- Array of ModuleScripts.
	@return boolean, Modules, Errors -- (Success, Modules, Errors)
]=]
function Bootstrapper.loadSequence(sequence: { ModuleScript }, predicate: Predicate?): (boolean, Modules, Errors)
	local services, errors = {}, {}
	for _, module in sequence do
		loadModule(module, services, errors, predicate)
	end
	return next(errors) == nil, services, errors
end

--[=[
	Converts a module collection into a deterministic array.
	Defaults to alphabetical sorting by module name if no sortFunction is provided.
	@function sort
	@within Bootstrapper
	@param modules { [string]: LoadedModule } | LoadedModule -- The collection to sort.
	@param sortFunction ((a: any, b: any) -> boolean)? -- Optional custom comparator.
	@return {any} -- Sorted array of modules.
]=]
function Bootstrapper.sort(
	modules: { [string]: LoadedModule } | LoadedModule,
	sortFunction: ((a: any, b: any) -> boolean)?
): { any }
	local result = {}

	for _, module in modules :: { [any]: any } do
		table.insert(result, module)
	end

	table.sort(result, sortFunction or function(a, b)
		return getModuleName(a, '') < getModuleName(b, '')
	end)

	return result
end

--[=[
	Executes a method on all modules and yields the calling thread until all modules have finished.
	Returns a success boolean, the surviving modules, and a map of crash errors.
	@yields
	@function callSync
	@within Bootstrapper
	@param modules Modules -- The dictionary or array of loaded modules.
	@param methodName string -- The name of the function to call on the modules.
	@param ... any -- Additional arguments to pass to the method.
	@return boolean, Modules, Errors -- (Success, Modules, Errors)
]=]
function Bootstrapper.callSync(modules: Modules, methodName: string, ...: any): (boolean, Modules, Errors)
	local mainThread = coroutine.running()
	local total, done = 0, 0
	local isYielded = false

	local passed: any = {}
	local errors: Errors = {}
	local isArray = (modules :: any)[1] ~= nil

	local batch = {}
	for key, value in modules :: { [any]: any } do
		local module, actualName = resolveModule(value, key, errors)
		if type(module) ~= 'table' then
			continue
		end

		local fn = module[methodName]
		if type(fn) == 'function' then
			total += 1
			table.insert(batch, {
				module = module,
				fn = fn,
				name = actualName,
				key = key,
			})
		end
	end

	if total == 0 then
		return true, passed :: Modules, errors
	end

	for _, entry in batch do
		task.spawn(function(...)
			debug.setmemorycategory(entry.name)

			local success, err = xpcall(function(...)
				entry.fn(entry.module, ...)
			end, function(e)
				return { msg = tostring(e), trace = debug.traceback('', 2) }
			end, ...)

			if success then
				if isArray then
					table.insert(passed, entry.module)
				else
					passed[entry.key] = entry.module
				end
			else
				errors[entry.name] = err.msg
				nonFatalError('Error in %s:%s()\n%s', err.trace, entry.name, methodName, err.msg)
			end

			done += 1

			if done == total then
				if isYielded then
					task.spawn(mainThread)
				end
			end
		end, ...)
	end

	if done < total then
		isYielded = true
		coroutine.yield()
	end

	return next(errors) == nil, passed :: Modules, errors
end

--[=[
	Executes a method on all modules asynchronously using `task.spawn` (Fire and forget).
	@function callAsync
	@within Bootstrapper
	@param modules Modules -- The dictionary or array of loaded modules.
	@param methodName string -- The name of the function to call on the modules.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.callAsync(modules: Modules, methodName: string, ...: any): ()
	for key, value in modules :: { [any]: any } do
		local module, actualName = resolveModule(value, key)
		if type(module) ~= 'table' then
			continue
		end

		local fn = module[methodName]
		if type(fn) == 'function' then
			task.spawn(function(...)
				debug.setmemorycategory(actualName)

				local success, err = xpcall(function(...)
					fn(module, ...)
				end, function(e)
					return { msg = tostring(e), trace = debug.traceback('', 2) }
				end, ...)

				if not success then
					nonFatalError('Error in %s:%s() (Async)\n%s', err.trace, actualName, methodName, err.msg)
				end
			end, ...)
		end
	end
end

--[=[
	Binds a method across all modules to a Signal, Custom Signal, or Callback Subscription.
	@function bind
	@within Bootstrapper
	@param modules Modules -- The dictionary or array of loaded modules.
	@param event Event -- A Signal or a subscription function.
	@param methodName string -- The name of the function to trigger.
	@return Cleanup -- A uniform cleanup function to disconnect the event.
]=]
function Bootstrapper.bind(modules: Modules, event: Event, methodName: string): Cleanup
	local tasks: { Task } = {}

	local b_modules = {}
	local b_fns = {}
	local b_names = {}
	local count = 0

	for key, value in modules :: { [any]: any } do
		local module, actualName = resolveModule(value, key)
		if type(module) ~= 'table' then
			continue
		end

		local fn = module[methodName]
		if type(fn) == 'function' then
			count += 1
			b_modules[count] = module
			b_fns[count] = fn
			b_names[count] = actualName
		end
	end

	if count == 0 then
		return function() end
	end

	local function run(...)
		for i = 1, count do
			debug.setmemorycategory(b_names[i])
			b_fns[i](b_modules[i], ...)
		end
	end

	if type(event) == 'function' then
		table.insert(tasks, event(run))
	else
		local connectMethod = (event :: any).Connect or (event :: any).connect
		table.insert(tasks, connectMethod(event, run))
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
	if not RunService:IsClient() then
		error(`[Bootstrapper] renderStepped can only be called on the Client.`, 3)
	end
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
	@return Cleanup
]=]
function Bootstrapper.preRender(modules: Modules, methodName: string): Cleanup
	if not RunService:IsClient() then
		error(`[Bootstrapper] preRender can only be called on the Client.`, 3)
	end
	return bindToRunService(modules, 'PreRender', methodName)
end

return Bootstrapper
