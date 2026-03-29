--!strict
--v1.2.0 • LDGerrits
--[=[
	@class Bootstrapper
	A lightweight, agnostic module loader and scheduler for Roblox. 
	Eliminate load-order bugs and race conditions by organizing your modules into a deterministic pipeline. 
	Define exactly what runs, and in what order, every single frame with zero ambiguity.
]=]

local RunService = game:GetService('RunService')

local batchCounter = 0
local moduleRegistry = setmetatable({}, { __mode = 'k' })

export type LoadedModule = { [string]: any }
export type LoadedModules = { LoadedModule }
export type ModulePath = string
export type ModulePaths = { ModulePath }
export type ModuleScripts = { ModuleScript }
export type Errors = { [string]: string }
export type PredicateFn = (module: ModuleScript) -> boolean
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

local function traceErrorHandler(e)
	return { msg = tostring(e), trace = debug.traceback('', 2) }
end

local function nonFatalError(messageTemplate: string, trace: string?, ...: any)
	local messageText = string.format(messageTemplate, ...)
	messageText = `[Bootstrapper] {messageText}`

	if trace and trace ~= '' then
		messageText ..= `\n---- Stack trace ----\n{trace}`
	end

	local formattedString = messageText:gsub('\n', '\n    ')

	task.spawn(error, formattedString, 0)
end

local function loadModule(value: any, errors: Errors?): (LoadedModule?, string?)
	if type(value) == 'table' then
		return value, moduleRegistry[value] or 'UnknownModule'
	end

	local identity: string
	local errorKey: string
	local sourceLabel: string

	if typeof(value) == 'Instance' and value:IsA('ModuleScript') then
		identity = value.Name
		errorKey = identity
		sourceLabel = 'ModuleScript'
	elseif type(value) == 'string' then
		identity = value:match('([^/]+)$') or value
		errorKey = value
		sourceLabel = 'string path'
	else
		return nil, nil
	end

	debug.setmemorycategory(identity)
	local success, result = pcall(require, value)
	debug.resetmemorycategory()

	if not success then
		local errMsg = tostring(result)
		if errors then
			errors[errorKey] = errMsg
		end
		nonFatalError("Failed to require %s '%s':\n%s", nil, sourceLabel, errorKey, errMsg)
		return nil, errorKey
	end

	if type(result) ~= 'table' then
		local errMsg = `Module must return a table; got {type(result)}`
		if errors then
			errors[errorKey] = errMsg
		end
		nonFatalError("Invalid %s '%s':\n%s", nil, sourceLabel, errorKey, errMsg)
		return nil, errorKey
	end

	moduleRegistry[result] = identity
	return result, identity
end

local function loadModules(
	modules: { Instance | ModulePath },
	shouldSort: boolean,
	predicate: PredicateFn?
): (LoadedModules, Errors?)
	local loadQueue = {}

	for _, item in modules do
		local isModuleScript = typeof(item) == 'Instance' and item:IsA('ModuleScript')
		local isModulePath = type(item) == 'string'

		if not (isModuleScript or isModulePath) then
			continue
		end

		if isModuleScript and predicate and not predicate(item :: ModuleScript) then
			continue
		end

		local identity = if isModuleScript
			then (item :: ModuleScript).Name
			else ((item :: ModulePath):match('([^/]+)$') or item)

		table.insert(loadQueue, {
			identity = identity,
			value = item,
			fullName = if isModuleScript then (item :: ModuleScript):GetFullName() else item,
		})
	end

	if shouldSort then
		table.sort(loadQueue, function(a, b)
			if a.identity == b.identity then
				return a.fullName < b.fullName
			end
			return a.identity < b.identity
		end)
	end

	local loadedModules: LoadedModules = {}
	local errors: Errors = {}
	for _, entry in loadQueue do
		local result, _ = loadModule(entry.value, errors)
		if result then
			table.insert(loadedModules, result)
		end
	end

	return loadedModules, next(errors) ~= nil and errors or nil
end

local function filterModules(modules: LoadedModules | ModuleScripts | ModulePaths, methodName: string)
	local loadedModules, callbacks, identities, count = {}, {}, {}, 0
	for _, item in modules :: any do
		local module, identity = loadModule(item)
		if not module then
			continue
		end

		local callback = module[methodName]
		if type(callback) == 'function' then
			count += 1
			loadedModules[count] = module
			callbacks[count] = callback
			identities[count] = identity :: string
		end
	end
	return loadedModules, callbacks, identities, count
end

local function parseMethodName(methodName: string): (string, boolean)
	local length = #methodName
	if length <= 1 then
		return methodName, true
	end

	local prefix = string.sub(methodName, 1, 1)
	if prefix == '.' then
		return string.sub(methodName, 2), false
	elseif prefix == ':' then
		return string.sub(methodName, 2), true
	end

	return methodName, true
end

local function dispatch(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	methodName: string,
	args: { [number]: any, n: number },
	mode: 'Sync' | 'Async' | 'Concurrent'
): (LoadedModules, Errors?)
	local parsedMethodName, includeSelf = parseMethodName(methodName)
	local loadedModules: LoadedModules = {}
	local errors: Errors = {}
	local errorSuffix = if mode == 'Sync' then '' else `({mode})`

	local function execute(item)
		local module, identity = loadModule(item, errors)
		if not module then
			return
		end

		local fn = module[parsedMethodName]
		if type(fn) ~= 'function' then
			return
		end

		debug.setmemorycategory(identity :: string)
		local success, err
		if includeSelf then
			success, err = xpcall(fn, traceErrorHandler, module, table.unpack(args, 1, args.n))
		else
			success, err = xpcall(fn, traceErrorHandler, table.unpack(args, 1, args.n))
		end
		debug.resetmemorycategory()

		if success then
			table.insert(loadedModules, module)
		else
			errors[identity :: string] = err.msg
			local suffixStr = errorSuffix ~= '' and ` {errorSuffix}` or ''
			nonFatalError('Error in %s:%s()%s\n%s', err.trace, identity :: string, parsedMethodName, suffixStr, err.msg)
		end
	end

	if mode == 'Sync' then
		for _, item in modules :: any do
			execute(item)
		end
	elseif mode == 'Async' then
		task.spawn(function()
			for _, item in modules :: any do
				execute(item)
			end
		end)
	else
		for _, item in modules :: any do
			task.spawn(execute, item)
		end
	end

	return loadedModules, next(errors) ~= nil and errors or nil
end

local function createRunner(
	loadedModules: LoadedModules,
	fns: { any },
	identities: { string },
	count: number,
	includeSelf: boolean
)
	return function(...)
		for i = 1, count do
			debug.setmemorycategory(identities[i])
			local success, err
			if not includeSelf then
				success, err = xpcall(fns[i], traceErrorHandler, ...)
			else
				success, err = xpcall(fns[i], traceErrorHandler, loadedModules[i], ...)
			end
			if not success then
				nonFatalError("Error in module '%s':\n%s", err.trace, identities[i], err.msg)
			end
		end
		debug.resetmemorycategory()
	end
end

local function bindToRunService(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	eventName: string,
	methodName: string,
	override: (number | EnumItem)?
): Cleanup
	local parsedMethodName, includeSelf = parseMethodName(methodName)
	local loadedModules, fns, identities, count = filterModules(modules, parsedMethodName)

	if count == 0 then
		return function() end
	end

	local run = createRunner(loadedModules, fns, identities, count, includeSelf)
	local task: Task
	if eventName == 'RenderStepped' then
		if type(override) == 'number' then
			batchCounter += 1
			local bindName = `Bootstrapper_RenderBatch_{batchCounter}_{parsedMethodName}`
			RunService:BindToRenderStep(bindName, override, run)
			task = function()
				RunService:UnbindFromRenderStep(bindName)
			end
		else
			task = RunService.RenderStepped:Connect(run)
		end
	elseif eventName == 'PreSimulation' then
		if typeof(override) == 'EnumItem' and (override :: EnumItem).EnumType == Enum.StepFrequency then
			task = RunService:BindToSimulation(run, override :: Enum.StepFrequency)
		else
			task = RunService.PreSimulation:Connect(run)
		end
	else
		local event = (RunService :: any)[eventName]
		if event then
			task = event:Connect(run)
		end
	end

	return function()
		doCleanup(task)
	end
end

local Bootstrapper = {}

--[=[
	Creates a predicate function that matches a module's name against a string.
	@function byName
	@within Bootstrapper
	@param matchName string -- The string pattern to match against the module's name.
	@return PredicateFn
]=]
function Bootstrapper.byName(matchName: string): PredicateFn
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
	@param predicate: PredicateFn? -- Optional filter to include specific modules (e.g., Bootstrapper.byName("Service$")).
	@return LoadedModules, Errors?
]=]
function Bootstrapper.loadChildren(parent: Instance, predicate: PredicateFn?): (LoadedModules, Errors?)
	return loadModules(parent:GetChildren(), true, predicate)
end

--[=[
	Requires all descendant ModuleScripts within a given parent.
	Returns an array of loaded modules to guarantee order execution.
	@yields
	@function loadDescendants
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param predicate: PredicateFn? -- Optional filter to include specific modules (e.g., Bootstrapper.byName("Service$")).
	@return LoadedModules, Errors?
]=]
function Bootstrapper.loadDescendants(parent: Instance, predicate: PredicateFn?): (LoadedModules, Errors?)
	return loadModules(parent:GetDescendants(), true, predicate)
end

--[=[
	Requires specific modules in a guaranteed sequence array.
	@yields
	@function loadSequence
	@within Bootstrapper
	@param modules ModuleScripts | ModulePaths -- The array of ModuleScripts or ModulePaths.
	@return LoadedModules, Errors?
]=]
function Bootstrapper.loadSequence(modules: ModuleScripts | ModulePaths): (LoadedModules, Errors?)
	return loadModules(modules, false)
end

--[=[
	Calls methods one-by-one and yields until complete.
	Guarantees that Module A is finished before Module B starts.
	@yields
	@function run
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param ... any -- Additional arguments to pass to the method.
	@return LoadedModules, Errors?
]=]
function Bootstrapper.run(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	methodName: string,
	...: any
): (LoadedModules, Errors?)
	return dispatch(modules, methodName, table.pack(...), 'Sync')
end

--[=[
	Calls methods one-by-one in a new thread.
	Maintains order but does not yield.
	@function runAsync
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.runAsync(modules: LoadedModules | ModuleScripts | ModulePaths, methodName: string, ...: any): ()
	dispatch(modules, methodName, table.pack(...), 'Async')
end

--[=[
	Calls all methods simultaneously using multiple threads.
	Fastest execution, but order of completion is not guaranteed.
	@function runConcurrent
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.runConcurrent(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	methodName: string,
	...: any
): ()
	dispatch(modules, methodName, table.pack(...), 'Concurrent')
end

--[=[
	Binds a method across all modules to an RBXScriptSignal, a custom Signal, or a subscription function.
	@function bindTo
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param event Event -- An RBXScriptSignal, custom Signal or a subscription function.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindTo(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	methodName: string,
	event: Event
): Cleanup
	local parsedMethodName, includeSelf = parseMethodName(methodName)
	local loadedModules, fns, identities, count = filterModules(modules, parsedMethodName)

	if count == 0 then
		return function() end
	end

	local run = createRunner(loadedModules, fns, identities, count, includeSelf)
	local task: Task
	if type(event) == 'function' then
		task = event(run)
	else
		local connectMethod = (event :: any).Connect or (event :: any).connect
		task = connectMethod(event, run)
	end

	return function()
		doCleanup(task)
	end
end

--[=[
	Binds a method to run at a specific time interval (in seconds) while not allowing drift.
	@function bindToInterval
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param interval number -- Time in seconds between calls.
	@param signal RBXScriptSignal? -- Optional signal to hook (defaults to Heartbeat).
	@return Cleanup -- A function to stop the interval.
]=]
function Bootstrapper.bindToInterval(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	methodName: string,
	interval: number,
	signal: RBXScriptSignal?
): Cleanup
	assert(interval > 0, `[Bootstrapper] interval must be greater than 0; got {interval}`)
	assert(
		signal ~= RunService.Stepped,
		'[Bootstrapper] bindToInterval cannot be used with Stepped. Use PreSimulation instead.'
	)

	local parsedMethodName, includeSelf = parseMethodName(methodName)
	local loadedModules, fns, identities, count = filterModules(modules, parsedMethodName)

	if count == 0 then
		return function() end
	end

	local run = createRunner(loadedModules, fns, identities, count, includeSelf)
	local startTime = os.clock()
	local nextTick = startTime + interval
	local lastFireTime = startTime
	local connection = ((signal or RunService.Heartbeat) :: RBXScriptSignal):Connect(function()
		local now = os.clock()
		if now >= nextTick then
			local dt = now - lastFireTime
			lastFireTime = now
			local intervalsPassed = math.floor((now - startTime) / interval)
			nextTick = startTime + (interval * (intervalsPassed + 1))
			run(dt)
		end
	end)

	return function()
		doCleanup(connection)
	end
end

--[=[
	Hooks a specified method in all modules to `RunService.Heartbeat`.
	@function bindToHeartbeat
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToHeartbeat(modules: LoadedModules | ModuleScripts | ModulePaths, methodName: string): Cleanup
	return bindToRunService(modules, 'Heartbeat', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.RenderStepped` 
	or `RunService:BindToRenderStep` if a priority is given.
	@client
	@function bindToRenderStep
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param priority number? -- Optional execution priority. If provided, uses BindToRenderStep instead of RenderStepped.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToRenderStep(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	methodName: string,
	priority: number?
): Cleanup
	assert(RunService:IsClient(), '[Bootstrapper] bindToRenderStep can only be called on the Client.')
	return bindToRunService(modules, 'RenderStepped', methodName, priority)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreSimulation`
	or `RunService:BindToSimulation` if a frequency is given.
	@function bindToPreSimulation
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param frequency Enum.StepFrequency? -- Optional execution frequency. If provided, uses BindToSimulation instead of PreSimulation.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPreSimulation(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	methodName: string,
	frequency: Enum.StepFrequency?
): Cleanup
	return bindToRunService(modules, 'PreSimulation', methodName, frequency)
end

--[=[
	Hooks a specified method in all modules to `RunService.PostSimulation`.
	@function bindToPostSimulation
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPostSimulation(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	methodName: string
): Cleanup
	return bindToRunService(modules, 'PostSimulation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreAnimation`.
	@function bindToPreAnimation
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPreAnimation(
	modules: LoadedModules | ModuleScripts | ModulePaths,
	methodName: string
): Cleanup
	return bindToRunService(modules, 'PreAnimation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreRender`.
	@client
	@function bindToPreRender
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts | ModulePaths -- The array of loaded modules, ModuleScripts, or ModulePaths.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPreRender(modules: LoadedModules | ModuleScripts | ModulePaths, methodName: string): Cleanup
	assert(RunService:IsClient(), '[Bootstrapper] bindToPreRender can only be called on the Client.')
	return bindToRunService(modules, 'PreRender', methodName)
end

return Bootstrapper
