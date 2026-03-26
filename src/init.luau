--!strict
--!nolint LocalUnused
--!nolint LocalShadow

local RunService = game:GetService('RunService')

export type Modules = { [string]: any } | { any }
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

local moduleNameRegistry = setmetatable({}, { __mode = 'k' })

local function getModuleName(module: any, fallbackKey: any): string
	if type(module) == 'table' then
		local registeredName = moduleNameRegistry[module]
		if registeredName then
			return registeredName
		end
	end
	return tostring(fallbackKey)
end

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

	for key, module in modules :: { [any]: any } do
		local fn = module[methodName]
		if type(fn) ~= 'function' then
			continue
		end

		local actualName = getModuleName(module, key)

		local function run(...)
			debug.setmemorycategory(actualName)
			local useSelf = shouldInjectSelf(module)
			if useSelf then
				fn(module, ...)
			else
				fn(...)
			end
		end

		if (eventName == 'RenderStepped' or eventName == 'PreRender') and RunService:IsClient() then
			if type(override) == 'number' then
				local bindName = `{actualName}_{methodName}`
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
	@yields
	@function loadChildren
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param options { predicate: Predicate?, self: boolean? }? -- Options for filtering and self-injection.
	@return boolean, Modules, {[ModuleScript]: string} -- (Success, Successful Modules, Failed Scripts)
]=]
function Bootstrapper.loadChildren(
	parent: Instance,
	options: {
		predicate: Predicate?,
		self: boolean?,
	}?
): (boolean, Modules, { [ModuleScript]: string })
	local modules: { [string]: any } = {}
	local failed: { [ModuleScript]: string } = {}

	local predicate = if options then options.predicate else nil
	local shouldInject = not options or options.self ~= false

	for _, child in parent:GetChildren() do
		if child:IsA('ModuleScript') then
			if predicate and not predicate(child) then
				continue
			end

			local success, req = pcall(require, child)
			if success then
				if type(req) == 'table' then
					injectSelfRegistry[req] = shouldInject
					moduleNameRegistry[req] = child.Name
				end
				modules[child.Name] = req
			else
				failed[child] = tostring(req)
				nonFatalError("Failed to load '%s':\n%s", nil, child.Name, tostring(req))
			end
		end
	end

	return next(failed) == nil, modules, failed
end

--[=[
	Requires all descendant ModuleScripts within a given parent.
	@yields
	@function loadDescendants
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param options { predicate: Predicate?, self: boolean? }? -- Options for filtering and self-injection.
	@return boolean, Modules, {[ModuleScript]: string} -- (Success, Successful Modules, Failed Scripts)
]=]
function Bootstrapper.loadDescendants(
	parent: Instance,
	options: {
		predicate: Predicate?,
		self: boolean?,
	}?
): (boolean, Modules, { [ModuleScript]: string })
	local modules: { [string]: any } = {}
	local failed: { [ModuleScript]: string } = {}

	local predicate = if options then options.predicate else nil
	local shouldInject = not options or options.self ~= false

	for _, descendant in parent:GetDescendants() do
		if descendant:IsA('ModuleScript') then
			if predicate and not predicate(descendant) then
				continue
			end

			local success, req = pcall(require, descendant)
			if success then
				if type(req) == 'table' then
					injectSelfRegistry[req] = shouldInject
					moduleNameRegistry[req] = descendant.Name
				end
				modules[descendant.Name] = req
			else
				failed[descendant] = tostring(req)
				nonFatalError("Failed to load '%s':\n%s", nil, descendant.Name, tostring(req))
			end
		end
	end

	return next(failed) == nil, modules, failed
end

--[=[
	Requires specific modules in a guaranteed order.
	@yields
	@function loadSequence
	@within Bootstrapper
	@param sequence {ModuleScript} -- Array of ModuleScripts.
	@param options { self: boolean? }? -- Options for self-injection.
	@return boolean, Modules, {[ModuleScript]: string} -- (Success, Ordered Modules, Failed Scripts)
]=]
function Bootstrapper.loadSequence(
	sequence: { ModuleScript },
	options: {
		self: boolean?,
	}?
): (boolean, Modules, { [ModuleScript]: string })
	local modules: { any } = {}
	local failed: { [ModuleScript]: string } = {}
	local shouldInject = not options or options.self ~= false

	for _, scriptInstance in sequence do
		if typeof(scriptInstance) == 'Instance' and scriptInstance:IsA('ModuleScript') then
			local success, req = pcall(require, scriptInstance)
			if success then
				if type(req) == 'table' then
					injectSelfRegistry[req] = shouldInject
					moduleNameRegistry[req] = scriptInstance.Name
				end
				table.insert(modules, req)
			else
				failed[scriptInstance] = tostring(req)
				nonFatalError("Sequence failed to load '%s':\n%s", nil, scriptInstance.Name, tostring(req))
			end
		else
			nonFatalError('Sequence item is not a ModuleScript: %s', nil, tostring(scriptInstance))
		end
	end

	return next(failed) == nil, modules, failed
end

--[=[
	Converts a module collection into a deterministic array.
	Defaults to alphabetical sorting by module name if no sortFunction is provided.
	@function sort
	@within Bootstrapper
	@param modules Modules -- The collection to sort.
	@param sortFunction ((a: any, b: any) -> boolean)? -- Optional custom comparator.
	@return {any} -- Sorted array of modules.
]=]
function Bootstrapper.sort(modules: Modules, sortFunction: ((a: any, b: any) -> boolean)?): { any }
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
	@return boolean, Modules, {[any]: string} -- (Success, Successful Modules, Failure Map)
]=]
function Bootstrapper.callSync(modules: Modules, methodName: string, ...: any): (boolean, Modules, { [any]: string })
	local mainThread = coroutine.running()
	local total, done = 0, 0
	local isYielded = false

	local iterModules = modules :: { [any]: any }
	local passed: any = {}
	local failed: { [any]: string } = {}
	local isArray = (modules :: any)[1] ~= nil

	for _, module in iterModules do
		if type(module[methodName]) == 'function' then
			total += 1
		end
	end

	if total == 0 then
		return true, passed :: Modules, failed
	end

	for key, module in iterModules do
		local fn = module[methodName]
		if type(fn) == 'function' then
			local useSelf = shouldInjectSelf(module)
			local actualName = getModuleName(module, key)

			task.spawn(function(...)
				debug.setmemorycategory(actualName)

				local success, err = xpcall(function(...)
					if useSelf then
						fn(module, ...)
					else
						fn(...)
					end
				end, function(e)
					return { msg = tostring(e), trace = debug.traceback('', 2) }
				end, ...)

				if success then
					if isArray then
						table.insert(passed, module)
					else
						passed[key] = module
					end
				else
					failed[module] = err.msg
					nonFatalError('Error in %s:%s()\n%s', err.trace, actualName, methodName, err.msg)
				end

				done += 1

				if done == total then
					if isYielded then
						task.spawn(mainThread)
					end
				end
			end, ...)
		end
	end

	if done < total then
		isYielded = true
		coroutine.yield()
	end

	return next(failed) == nil, passed :: Modules, failed
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
	for key, module in modules :: { [any]: any } do
		local fn = module[methodName]
		if type(fn) == 'function' then
			local useSelf = shouldInjectSelf(module)
			local actualName = getModuleName(module, key)

			local function wrapper(...)
				debug.setmemorycategory(actualName)
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
	@param modules Modules -- The dictionary or array of loaded modules.
	@param source EventSource -- A Signal (e.g., PlayerAdded) or a subscription function.
	@param methodName string -- The name of the function to trigger.
	@return Cleanup -- A uniform cleanup function to disconnect the event.
]=]
function Bootstrapper.bind(modules: Modules, source: EventSource, methodName: string): Cleanup
	local tasks: { Task } = {}

	if type(source) == 'function' then
		for key, module in modules :: { [any]: any } do
			local fn = module[methodName]
			if type(fn) == 'function' then
				local actualName = getModuleName(module, key)
				local taskInstance = source(function(...)
					local useSelf = shouldInjectSelf(module)
					task.spawn(function(...)
						debug.setmemorycategory(actualName)
						if useSelf then
							fn(module, ...)
						else
							fn(...)
						end
					end, ...)
				end)
				table.insert(tasks, taskInstance)
			end
		end
	else
		local connectMethod = (source :: any).Connect or (source :: any).connect
		local connection = connectMethod(source, function(...)
			for key, module in modules :: { [any]: any } do
				local fn = module[methodName]
				if type(fn) == 'function' then
					local actualName = getModuleName(module, key)
					local useSelf = shouldInjectSelf(module)
					task.spawn(function(...)
						debug.setmemorycategory(actualName)
						if useSelf then
							fn(module, ...)
						else
							fn(...)
						end
					end, ...)
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

return Bootstrapper
