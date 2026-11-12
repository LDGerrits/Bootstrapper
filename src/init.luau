--!strict
--v2.0.0 • LDGerrits
--[=[
	@class Bootstrapper
	A lightweight, agnostic module loader and scheduler for Roblox.
	Eliminate load-order bugs and race conditions by organizing your modules into a deterministic pipeline.
	Define exactly what runs, and in what order, every single frame.
]=]

local RunService = game:GetService('RunService')

local YIELD_WARNING_TIME = 10

local batchCounter = 0
local isProfiling = false
local moduleSources = setmetatable({}, { __mode = 'k' })

export type LoadedModule = { [string]: any }
export type LoadedModules = { LoadedModule }
export type ModulePath = string
export type ModuleList = { Instance | ModulePath | LoadedModule }
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

local function doCleanup(task: any)
	if typeof(task) == 'Instance' then
		task:Destroy()
	elseif typeof(task) == 'RBXScriptConnection' then
		task:Disconnect()
	elseif type(task) == 'function' then
		task()
	elseif type(task) == 'table' then
		local method = task.destroy or task.Destroy or task.Disconnect or task.disconnect
		if type(method) == 'function' then
			method(task)
		else
			for _, subtask in task do
				doCleanup(subtask)
			end
		end
	end
end

local function traceErrorHandler(e)
	return { msg = tostring(e), trace = debug.traceback('', 2) }
end

local function reportError(message: string, trace: string?)
	if trace then
		message ..= `\n---- Stack trace ----\n{trace}`
	end
	local formatted = (`[Bootstrapper] {message}`):gsub('\n', '\n    ')
	task.spawn(error, formatted, 0)
end

local function addError(errors: Errors, key: string, message: string)
	local uniqueKey = key
	local count = 1
	while errors[uniqueKey] do
		count += 1
		uniqueKey = `{key} ({count})`
	end
	errors[uniqueKey] = message
end

-- Returns a module's short name and its unique full name
local function getNames(value: any): (string, string)
	local source = if type(value) == 'table' then moduleSources[value] else value
	if typeof(source) == 'Instance' then
		return source.Name, source:GetFullName()
	elseif type(source) == 'string' then
		return source:match('[^/]+$') or source, source
	end
	return 'UnknownModule', 'UnknownModule'
end

local function loadModule(value: any, errors: Errors?): (LoadedModule?, string, string)
	local name, fullName = getNames(value)
	if type(value) == 'table' then
		return value, name, fullName
	end

	debug.setmemorycategory(name)
	local success, result = pcall(require, value)
	debug.resetmemorycategory()

	if success and type(result) ~= 'table' then
		success, result = false, `Module must return a table; got {type(result)}`
	end

	if not success then
		if errors then
			addError(errors, fullName, tostring(result))
		end
		reportError(`Failed to load '{fullName}':\n{result}`)
		return nil, name, fullName
	end

	moduleSources[result] = value
	return result, name, fullName
end

local function getModuleScripts(instances: { Instance }, predicate: PredicateFn?): { ModuleScript }
	local moduleScripts: { ModuleScript } = {}
	for _, instance in instances do
		if instance:IsA('ModuleScript') and (not predicate or predicate(instance :: ModuleScript)) then
			table.insert(moduleScripts, instance :: ModuleScript)
		end
	end

	table.sort(moduleScripts, function(a, b)
		if a.Name == b.Name then
			return a:GetFullName() < b:GetFullName()
		end
		return a.Name < b.Name
	end)
	return moduleScripts
end

-- Expands folders into their ModuleScripts and removes duplicates
local function resolveModules(modules: ModuleList): { any }
	local queue = {}
	local seen = {}
	local function add(value: any)
		if not seen[value] then
			seen[value] = true
			table.insert(queue, value)
		end
	end

	for _, value in modules do
		if typeof(value) == 'Instance' and not value:IsA('ModuleScript') then
			for _, moduleScript in getModuleScripts(value:GetChildren()) do
				add(moduleScript)
			end
		else
			add(value)
		end
	end
	return queue
end

local function loadModules(modules: ModuleList): (LoadedModules, Errors?)
	local loadedModules: LoadedModules = {}
	local errors: Errors = {}
	for _, value in resolveModules(modules) do
		local module = loadModule(value, errors)
		if module then
			table.insert(loadedModules, module)
		end
	end
	return loadedModules, next(errors) ~= nil and errors or nil
end

-- '.method' calls without self, ':method' and 'method' pass the module as self
local function parseMethodName(methodName: string): (string, boolean)
	local prefix = methodName:sub(1, 1)
	if prefix == '.' or prefix == ':' then
		return methodName:sub(2), prefix == ':'
	end
	return methodName, true
end

local function callMethod(module: LoadedModule, name: string, methodName: string, includeSelf: boolean, ...: any)
	debug.setmemorycategory(name)
	local success, err
	if includeSelf then
		success, err = xpcall(module[methodName], traceErrorHandler, module, ...)
	else
		success, err = xpcall(module[methodName], traceErrorHandler, ...)
	end
	debug.resetmemorycategory()

	if not success then
		reportError(`Error in {name}:{methodName}()\n{err.msg}`, err.trace)
		return err.msg
	end
	return nil
end

local function dispatch(
	modules: ModuleList,
	methodName: string,
	args: { [number]: any, n: number },
	isConcurrent: boolean,
	shouldWait: boolean
): (LoadedModules, Errors?)
	local parsedMethodName, includeSelf = parseMethodName(methodName)
	local queue = resolveModules(modules)
	local results: { [number]: LoadedModule? } = {}
	local running: { [number]: boolean } = {}
	local errors: Errors = {}

	local function execute(index: number)
		running[index] = true
		local module, name, fullName = loadModule(queue[index], errors)
		if module and type(module[parsedMethodName]) == 'function' then
			local err = callMethod(module, name, parsedMethodName, includeSelf, table.unpack(args, 1, args.n))
			if err then
				addError(errors, fullName, err)
				module = nil
			end
		end
		results[index] = module
		running[index] = nil
	end

	local function warnStillRunning()
		local names = {}
		for index = 1, #queue do
			if running[index] then
				table.insert(names, (getNames(queue[index])))
			end
		end
		local waitingOn = table.concat(names, ', ')
		warn(
			`[Bootstrapper] Infinite yield possible: '{methodName}' is still running in {waitingOn}. Use spawn() or spawnConcurrent() for methods that never return.`
		)
	end

	local warningThread = if shouldWait then task.delay(YIELD_WARNING_TIME, warnStillRunning) else nil

	if isConcurrent then
		local pending = #queue
		local isWaiting = false
		local caller = coroutine.running()
		for index in queue do
			task.spawn(function()
				execute(index)
				pending -= 1
				if pending == 0 and isWaiting then
					task.spawn(caller)
				end
			end)
		end

		-- Only yield if a method yielded, otherwise nothing would resume us
		if shouldWait and pending > 0 then
			isWaiting = true
			coroutine.yield()
		end
	else
		for index in queue do
			execute(index)
		end
	end

	if warningThread then
		task.cancel(warningThread)
	end

	local loadedModules: LoadedModules = {}
	for index = 1, #queue do
		local module = results[index]
		if module then
			table.insert(loadedModules, module)
		end
	end
	return loadedModules, next(errors) ~= nil and errors or nil
end

-- Calls the method on every module each time the event fires
local function bind(modules: ModuleList, methodName: string, event: Event): Cleanup
	local parsedMethodName, includeSelf = parseMethodName(methodName)
	local targets: { { module: LoadedModule, method: (...any) -> ...any, name: string, label: string } } = {}
	for _, value in resolveModules(modules) do
		local module, name = loadModule(value)
		if module and type(module[parsedMethodName]) == 'function' then
			table.insert(targets, {
				module = module,
				method = module[parsedMethodName],
				name = name,
				label = `{name}:{parsedMethodName}`,
			})
		end
	end

	if #targets == 0 then
		return function() end
	end

	-- Runs every frame, so it uses one xpcall for all modules and resumes after the module that errored
	local function run(...)
		local index = 0
		local profiling = isProfiling
		local function callRemaining(...: any): ...any
			while index < #targets do
				index += 1
				local target = targets[index]
				if profiling then
					debug.profilebegin(target.label)
					debug.setmemorycategory(target.name)
				end
				if includeSelf then
					target.method(target.module, ...)
				else
					target.method(...)
				end
				if profiling then
					debug.profileend()
				end
			end
		end

		while index < #targets do
			local success, err = xpcall(callRemaining, traceErrorHandler, ...)
			if not success then
				if profiling then
					debug.profileend()
				end
				reportError(`Error in {targets[index].label}()\n{err.msg}`, err.trace)
			end
		end
		if profiling then
			debug.resetmemorycategory()
		end
	end

	local connection = if type(event) == 'function'
		then event(run)
		else ((event :: any).Connect or (event :: any).connect)(event, run)
	return function()
		doCleanup(connection)
	end
end

local Bootstrapper = {}

--[=[
	Enables MicroProfiler labels and memory categories for every bound method.
	Disabled by default for performance. Loading, `run` and `spawn` always set memory categories.
	@function setProfiling
	@within Bootstrapper
	@param enabled boolean
]=]
function Bootstrapper.setProfiling(enabled: boolean)
	isProfiling = enabled
end

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
	@param predicate PredicateFn? -- Optional filter to include specific modules (e.g., Bootstrapper.byName("Service$")).
	@return LoadedModules, Errors?
]=]
function Bootstrapper.loadChildren(parent: Instance, predicate: PredicateFn?): (LoadedModules, Errors?)
	return loadModules(getModuleScripts(parent:GetChildren(), predicate))
end

--[=[
	Requires all descendant ModuleScripts within a given parent.
	Returns an array of loaded modules to guarantee order execution.
	@yields
	@function loadDescendants
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param predicate PredicateFn? -- Optional filter to include specific modules (e.g., Bootstrapper.byName("Service$")).
	@return LoadedModules, Errors?
]=]
function Bootstrapper.loadDescendants(parent: Instance, predicate: PredicateFn?): (LoadedModules, Errors?)
	return loadModules(getModuleScripts(parent:GetDescendants(), predicate))
end

--[=[
	Requires specific modules in a guaranteed sequence array.
	@yields
	@function loadSequence
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@return LoadedModules, Errors?
]=]
function Bootstrapper.loadSequence(modules: ModuleList): (LoadedModules, Errors?)
	return loadModules(modules)
end

--[=[
	Calls methods one-by-one and yields until complete.
	Guarantees that Module A is finished before Module B starts.
	Returns every loaded module except those whose method errored, so the result can be passed to the next stage.
	Warns if still yielding after 10 seconds. Use `spawn` for methods that never return.
	@yields
	@function run
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param ... any -- Additional arguments to pass to the method.
	@return LoadedModules, Errors?
]=]
function Bootstrapper.run(modules: ModuleList, methodName: string, ...: any): (LoadedModules, Errors?)
	return dispatch(modules, methodName, table.pack(...), false, true)
end

--[=[
	Calls all methods simultaneously using multiple threads and yields until all are complete.
	Methods start in order, but order of completion is not guaranteed.
	Returns every loaded module except those whose method errored, in their original order.
	Warns if still yielding after 10 seconds. Use `spawnConcurrent` for methods that never return.
	@yields
	@function runConcurrent
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param ... any -- Additional arguments to pass to the method.
	@return LoadedModules, Errors?
]=]
function Bootstrapper.runConcurrent(modules: ModuleList, methodName: string, ...: any): (LoadedModules, Errors?)
	return dispatch(modules, methodName, table.pack(...), true, true)
end

--[=[
	Calls methods one-by-one in a new thread.
	Maintains order but does not yield.
	@function spawn
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.spawn(modules: ModuleList, methodName: string, ...: any): ()
	task.spawn(dispatch, modules, methodName, table.pack(...), false, false)
end

--[=[
	Calls all methods simultaneously using multiple threads.
	Fastest execution and does not yield, but order of completion is not guaranteed.
	@function spawnConcurrent
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.spawnConcurrent(modules: ModuleList, methodName: string, ...: any): ()
	dispatch(modules, methodName, table.pack(...), true, false)
end

--[=[
	Binds a method across all modules to an RBXScriptSignal, a custom Signal, or a subscription function.
	@function bindTo
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param event Event -- An RBXScriptSignal, custom Signal or a subscription function.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindTo(modules: ModuleList, methodName: string, event: Event): Cleanup
	return bind(modules, methodName, event)
end

--[=[
	Binds a method to run at a specific time interval (in seconds) while not allowing drift.
	@function bindToInterval
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param interval number -- Time in seconds between calls.
	@param signal RBXScriptSignal? -- Optional signal to hook (defaults to Heartbeat).
	@return Cleanup -- A function to stop the interval.
]=]
function Bootstrapper.bindToInterval(
	modules: ModuleList,
	methodName: string,
	interval: number,
	signal: RBXScriptSignal?
): Cleanup
	assert(interval > 0, `[Bootstrapper] interval must be greater than 0; got {interval}`)
	assert(
		signal ~= RunService.Stepped,
		'[Bootstrapper] bindToInterval cannot be used with Stepped. Use PreSimulation instead.'
	)

	return bind(modules, methodName, function(run)
		local startTime = os.clock()
		local nextTick = startTime + interval
		local lastFireTime = startTime
		return ((signal or RunService.Heartbeat) :: RBXScriptSignal):Connect(function()
			local now = os.clock()
			if now >= nextTick then
				local intervalsPassed = math.floor((now - startTime) / interval)
				nextTick = startTime + interval * (intervalsPassed + 1)
				local dt = now - lastFireTime
				lastFireTime = now
				run(dt)
			end
		end)
	end)
end

--[=[
	Hooks a specified method in all modules to `RunService.Heartbeat`.
	@function bindToHeartbeat
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToHeartbeat(modules: ModuleList, methodName: string): Cleanup
	return bind(modules, methodName, RunService.Heartbeat)
end

--[=[
	Hooks a specified method in all modules to `RunService.RenderStepped`
	or `RunService:BindToRenderStep` if a priority is given.
	@client
	@function bindToRenderStep
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param priority number? -- Optional execution priority. If provided, uses BindToRenderStep instead of RenderStepped.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToRenderStep(modules: ModuleList, methodName: string, priority: number?): Cleanup
	assert(RunService:IsClient(), '[Bootstrapper] bindToRenderStep can only be called on the Client.')
	if not priority then
		return bind(modules, methodName, RunService.RenderStepped)
	end

	batchCounter += 1
	local bindName = `Bootstrapper_RenderBatch_{batchCounter}_{parseMethodName(methodName)}`
	return bind(modules, methodName, function(run)
		RunService:BindToRenderStep(bindName, priority, run)
		return function()
			RunService:UnbindFromRenderStep(bindName)
		end
	end)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreSimulation`
	or `RunService:BindToSimulation` if a frequency is given.
	@function bindToPreSimulation
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@param frequency Enum.StepFrequency? -- Optional execution frequency. If provided, uses BindToSimulation instead of PreSimulation.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPreSimulation(
	modules: ModuleList,
	methodName: string,
	frequency: Enum.StepFrequency?
): Cleanup
	if not frequency then
		return bind(modules, methodName, RunService.PreSimulation)
	end
	return bind(modules, methodName, function(run)
		return RunService:BindToSimulation(run, frequency)
	end)
end

--[=[
	Hooks a specified method in all modules to `RunService.PostSimulation`.
	@function bindToPostSimulation
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPostSimulation(modules: ModuleList, methodName: string): Cleanup
	return bind(modules, methodName, RunService.PostSimulation)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreAnimation`.
	@function bindToPreAnimation
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPreAnimation(modules: ModuleList, methodName: string): Cleanup
	return bind(modules, methodName, RunService.PreAnimation)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreRender`.
	@client
	@function bindToPreRender
	@within Bootstrapper
	@param modules { Instance | ModulePath | LoadedModule } -- An array of ModuleScripts, Paths, Folders, or loaded modules.
	@param methodName string -- The method to call. Prefix with '.' for standard calls; otherwise, the module is implicitly passed as 'self'.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPreRender(modules: ModuleList, methodName: string): Cleanup
	assert(RunService:IsClient(), '[Bootstrapper] bindToPreRender can only be called on the Client.')
	return bind(modules, methodName, RunService.PreRender)
end

return Bootstrapper
