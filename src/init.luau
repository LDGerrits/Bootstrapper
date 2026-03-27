-- Bootstrapper v1.1.0 • LDGerrits
--!strict
--!nolint LocalUnused
--!nolint LocalShadow

local RunService = game:GetService('RunService')

local batchCounter = 0
local moduleNameRegistry = setmetatable({}, { __mode = 'k' })

export type LoadedModule = { [string]: any }
export type LoadedModules = { LoadedModule }
export type ModuleScripts = { ModuleScript }
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

local function ensureLoaded(value: any, errors: Errors?): (LoadedModule?, string?)
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
			nonFatalError("Failed to resolve ModuleScript '%s':\n%s", nil, errName, errMsg)
			return nil, errName
		end
	elseif type(value) == 'table' then
		return value, moduleNameRegistry[value] or 'UnknownModule'
	end
	return nil, nil
end

local function loadModule(module: ModuleScript, modulesArray: { any }, errors: Errors, predicate: Predicate?)
	if predicate and not predicate(module) then
		return
	end

	local success, result = pcall(require, module)
	if success then
		if type(result) == 'table' then
			moduleNameRegistry[result] = module.Name
		end
		table.insert(modulesArray, result)
	else
		errors[module.Name] = tostring(result)
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
	modules: { LoadedModule | ModuleScript },
	eventName: string,
	methodName: string,
	override: (number | EnumItem)?
): Cleanup
	local tasks: { Task } = {}

	local b_modules = {}
	local b_fns = {}
	local b_names = {}
	local count = 0

	for _, item in modules do
		local module, actualName = ensureLoaded(item)
		if type(module) ~= 'table' then
			continue
		end

		local fn = module[methodName]
		if type(fn) == 'function' then
			count += 1
			b_modules[count] = module
			b_fns[count] = fn
			b_names[count] = actualName :: string
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

	if eventName == 'RenderStepped' then
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
	elseif eventName == 'PreRender' then
		table.insert(tasks, RunService.PreRender:Connect(run))
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
	Returns an array of loaded modules to guarantee order execution.
	@yields
	@function loadChildren
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param predicate: Predicate? -- Filter
	@return boolean, LoadedModules, Errors -- (Success, LoadedModules, Errors)
]=]
function Bootstrapper.loadChildren(parent: Instance, predicate: Predicate?): (boolean, LoadedModules, Errors)
	local modulesArray, errors = {}, {}

	local scripts = {}
	for _, child in parent:GetChildren() do
		if child:IsA('ModuleScript') then
			table.insert(scripts, child)
		end
	end

	table.sort(scripts, function(a, b)
		return a.Name < b.Name
	end)

	for _, moduleScript in scripts do
		loadModule(moduleScript, modulesArray, errors, predicate)
	end

	return next(errors) == nil, modulesArray, errors
end

--[=[
	Requires all descendant ModuleScripts within a given parent.
	Returns an array of loaded modules to guarantee order execution.
	@yields
	@function loadDescendants
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param predicate: Predicate? -- Filter
	@return boolean, LoadedModules, Errors -- (Success, LoadedModules, Errors)
]=]
function Bootstrapper.loadDescendants(parent: Instance, predicate: Predicate?): (boolean, LoadedModules, Errors)
	local modulesArray, errors = {}, {}

	local scripts = {}
	for _, descendant in parent:GetDescendants() do
		if descendant:IsA('ModuleScript') then
			table.insert(scripts, descendant)
		end
	end

	table.sort(scripts, function(a, b)
		return a.Name < b.Name
	end)

	for _, moduleScript in scripts do
		loadModule(moduleScript, modulesArray, errors, predicate)
	end

	return next(errors) == nil, modulesArray, errors
end

--[=[
	Requires specific modules in a guaranteed sequence array.
	@yields
	@function loadSequence
	@within Bootstrapper
	@param modules ModuleScripts -- Array of ModuleScripts.
	@return boolean, LoadedModules, Errors -- (Success, LoadedModules, Errors)
]=]
function Bootstrapper.loadSequence(modules: ModuleScripts, predicate: Predicate?): (boolean, LoadedModules, Errors)
	local modulesArray, errors = {}, {}
	for _, module in modules do
		loadModule(module, modulesArray, errors, predicate)
	end
	return next(errors) == nil, modulesArray, errors
end

--[=[
	Executes a method on all modules and yields the calling thread until all modules have finished.
	Returns a success boolean, the surviving modules array, and a map of crash errors.
	@yields
	@function callSync
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts.
	@param methodName string -- The name of the function to call on the modules.
	@param ... any -- Additional arguments to pass to the method.
	@return boolean, LoadedModules, Errors -- (Success, LoadedModules, Errors)
]=]
function Bootstrapper.callSync(
	modules: LoadedModules | ModuleScripts,
	methodName: string,
	...: any
): (boolean, LoadedModules, Errors)
	local mainThread = coroutine.running()
	local total, done = 0, 0
	local isYielded = false

	local passed: LoadedModules = {}
	local errors: Errors = {}

	local batch = {}
	for _, item in modules :: { [any]: any } do
		local module, actualName = ensureLoaded(item, errors)
		if type(module) ~= 'table' then
			continue
		end

		local fn = module[methodName]
		if type(fn) == 'function' then
			total += 1
			table.insert(batch, {
				module = module,
				fn = fn,
				name = actualName :: string,
			})
		end
	end

	if total == 0 then
		return true, passed, errors
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
				table.insert(passed, entry.module)
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

	return next(errors) == nil, passed, errors
end

--[=[
	Executes a method on all modules asynchronously using `task.spawn` (Fire and forget).
	Catches and logs errors safely to prevent thread crashing.
	@function callAsync
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts.
	@param methodName string -- The name of the function to call on the modules.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.callAsync(modules: LoadedModules | ModuleScripts, methodName: string, ...: any): ()
	for _, item in modules :: { [any]: any } do
		local module, actualName = ensureLoaded(item)
		if type(module) ~= 'table' then
			continue
		end

		local fn = module[methodName]
		if type(fn) == 'function' then
			task.spawn(function(...)
				debug.setmemorycategory(actualName :: string)

				local success, err = xpcall(function(...)
					fn(module, ...)
				end, function(e)
					return { msg = tostring(e), trace = debug.traceback('', 2) }
				end, ...)

				if not success then
					nonFatalError('Error in %s:%s() (Async)\n%s', err.trace, actualName :: string, methodName, err.msg)
				end
			end, ...)
		end
	end
end

--[=[
	Binds a method across all modules to a Signal, Custom Signal, or Callback Subscription.
	@function bind
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts.
	@param event Event -- A Signal or a subscription function.
	@param methodName string -- The name of the function to trigger.
	@return Cleanup -- A uniform cleanup function to disconnect the event.
]=]
function Bootstrapper.bind(modules: LoadedModules | ModuleScripts, event: Event, methodName: string): Cleanup
	local tasks: { Task } = {}

	local b_modules = {}
	local b_fns = {}
	local b_names = {}
	local count = 0

	for _, item in modules :: { [any]: any } do
		local module, actualName = ensureLoaded(item)
		if type(module) ~= 'table' then
			continue
		end

		local fn = module[methodName]
		if type(fn) == 'function' then
			count += 1
			b_modules[count] = module
			b_fns[count] = fn
			b_names[count] = actualName :: string
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
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The name of the function to trigger.
	@return Cleanup
]=]
function Bootstrapper.heartbeat(modules: LoadedModules | ModuleScripts, methodName: string): Cleanup
	return bindToRunService(modules, 'Heartbeat', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.RenderStepped` (Client-side only).
	@function renderStepped
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The name of the function to trigger.
	@param priority number?
	@return Cleanup
]=]
function Bootstrapper.renderStepped(
	modules: LoadedModules | ModuleScripts,
	methodName: string,
	priority: number?
): Cleanup
	if not RunService:IsClient() then
		error(`[Bootstrapper] renderStepped can only be called on the Client.`, 3)
	end
	return bindToRunService(modules, 'RenderStepped', methodName, priority)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreSimulation`. 
	@function preSimulation
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The name of the function to trigger.
	@param frequency Enum.StepFrequency?
	@return Cleanup
]=]
function Bootstrapper.preSimulation(
	modules: LoadedModules | ModuleScripts,
	methodName: string,
	frequency: Enum.StepFrequency?
): Cleanup
	return bindToRunService(modules, 'PreSimulation', methodName, frequency)
end

--[=[
	Hooks a specified method in all modules to `RunService.PostSimulation`.
	@function postSimulation
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The name of the function to trigger.
	@return Cleanup
]=]
function Bootstrapper.postSimulation(modules: LoadedModules | ModuleScripts, methodName: string): Cleanup
	return bindToRunService(modules, 'PostSimulation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreAnimation`.
	@function preAnimation
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The name of the function to trigger.
	@return Cleanup
]=]
function Bootstrapper.preAnimation(modules: LoadedModules | ModuleScripts, methodName: string): Cleanup
	return bindToRunService(modules, 'PreAnimation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreRender` (Client-side only).
	@function preRender
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The name of the function to trigger.
	@return Cleanup
]=]
function Bootstrapper.preRender(modules: LoadedModules | ModuleScripts, methodName: string): Cleanup
	if not RunService:IsClient() then
		error(`[Bootstrapper] preRender can only be called on the Client.`, 3)
	end
	return bindToRunService(modules, 'PreRender', methodName)
end

return Bootstrapper
