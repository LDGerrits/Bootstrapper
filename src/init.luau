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
	A lightweight and unopinionated lifecycle manager for Roblox. 
	Find and load modules, run their functions, and bind them to RunService events.
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
	@function loadChildren
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param options { predicate: Predicate?, self: boolean? }? -- Options for filtering and self-injection.
	@return Modules, {[ModuleScript]: string} -- (Successful Modules, Failed Scripts)
]=]
function Bootstrapper.loadChildren(
	parent: Instance,
	options: {
		predicate: Predicate?,
		self: boolean?,
	}?
): (Modules, { [ModuleScript]: string })
	local modules = {}
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

	return modules, failed
end

--[=[
	Requires all descendant ModuleScripts within a given parent.
	@function loadDescendants
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param options { predicate: Predicate?, self: boolean? }? -- Options for filtering and self-injection.
	@return Modules, {[ModuleScript]: string} -- (Successful Modules, Failed Scripts)
]=]
function Bootstrapper.loadDescendants(
	parent: Instance,
	options: {
		predicate: Predicate?,
		self: boolean?,
	}?
): (Modules, { [ModuleScript]: string })
	local modules = {}
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

	return modules, failed
end

--[=[
	Requires specific modules in a guaranteed order.
	@function loadSequence
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param sequence -- Array of ModuleScripts or strings.
	@param options { predicate: Predicate?, self: boolean? }? -- Options for filtering and self-injection.
	@return {any}, {[ModuleScript]: string} -- (Ordered Modules, Failed Scripts)
]=]
function Bootstrapper.loadSequence(
	parent: Instance,
	sequence: { string | ModuleScript },
	options: {
		predicate: Predicate?,
		self: boolean?,
	}?
): ({ any }, { [ModuleScript]: string })
	local modules = {}
	local failed: { [ModuleScript]: string } = {}
	local shouldInject = not options or options.self ~= false

	for _, item in sequence do
		local child: ModuleScript?

		if typeof(item) == 'Instance' and item:IsA('ModuleScript') then
			child = item
		elseif type(item) == 'string' and parent then
			child = parent:FindFirstChild(item) :: ModuleScript
		end

		if child then
			local success, req = pcall(require, child)
			if success then
				if type(req) == 'table' then
					injectSelfRegistry[req] = shouldInject
					moduleNameRegistry[req] = child.Name
				end
				table.insert(modules, req)
			else
				failed[child] = tostring(req)
				nonFatalError("Sequence failed to load '%s':\n%s", nil, child.Name, tostring(req))
			end
		else
			nonFatalError('Sequence could not find module: %s', nil, tostring(item))
		end
	end

	return modules, failed
end

--[=[
	Converts a module dictionary into a deterministic array.
	If no sort function is provided, it defaults to alphabetical by module name.
	@function getSorted
	@within Bootstrapper
	@param modules Modules -- The dictionary of modules to sort.
	@param sortFunction ((a: string, b: string) -> boolean)? -- Optional custom sort function.
	@return {any} -- An array of modules sorted deterministically.
]=]
function Bootstrapper.getSorted(modules: Modules, sortFunction: ((a: string, b: string) -> boolean)?): { any }
	local iterModules = modules :: { [string]: any }
	local keys = {}

	for name in iterModules do
		table.insert(keys, name)
	end

	table.sort(keys, sortFunction or function(a, b)
		return a < b
	end)

	local sorted = {}
	for _, name in keys do
		table.insert(sorted, iterModules[name])
	end

	return sorted
end

--[=[
	Combines multiple module collections into a single collection.
	If all inputs are arrays, the result is an array. If any are dictionaries, the result is a dictionary.
	@function combine
	@within Bootstrapper
	@param ... Modules -- Variadic list of module collections to merge.
	@return Modules -- The merged collection.
]=]
function Bootstrapper.combine(...: Modules): Modules
	local args = { ... }
	local isAllArray = true

	for _, collection in args do
		if not (collection :: any)[1] and next(collection :: any) ~= nil then
			isAllArray = false
			break
		end
	end

	if isAllArray then
		local result = {}
		for _, collection in args do
			for _, module in collection :: { any } do
				table.insert(result, module)
			end
		end
		return result
	else
		local result: { [string]: any } = {}
		for _, collection in args do
			for key, module in collection :: { [any]: any } do
				result[tostring(key)] = module
			end
		end
		return result
	end
end

--[=[
	Executes a method on all modules and yields the calling thread until all modules have finished.
	Returns (passed, failed) where passed matches the input structure (Array or Map).
	@yields
	@function callSync
	@within Bootstrapper
	@param modules Modules -- The dictionary or array of loaded modules.
	@param methodName string -- The name of the function to call on the modules.
	@param ... any -- Additional arguments to pass to the method.
	@return Modules, {[any]: string} -- (Successful Modules, Failure Map)
]=]
function Bootstrapper.callSync(modules: Modules, methodName: string, ...: any): (Modules, { [any]: string })
	local mainThread = coroutine.running()
	local total, done = 0, 0

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
		return passed, failed
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
					task.spawn(mainThread)
				end
			end, ...)
		end
	end

	coroutine.yield()
	return passed, failed
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
