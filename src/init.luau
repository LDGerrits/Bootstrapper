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

local function sortByName(a: Instance, b: Instance)
	return a.Name < b.Name
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

local function loadFromInstances(instances: { Instance }, predicate: Predicate?): (LoadedModules, Errors?)
	local modulesArray, errors = {}, {}
	local scripts = {}

	for _, inst in instances do
		if inst:IsA('ModuleScript') then
			table.insert(scripts, inst)
		end
	end

	table.sort(scripts, sortByName)

	for _, module in scripts do
		if predicate and not predicate(module) then
			continue
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

	return modulesArray, next(errors) ~= nil and errors or nil
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

local function buildBatch(modules: { any }, queryName: string)
	local b_modules, b_fns, b_names, count = {}, {}, {}, 0
	for _, item in modules do
		local module, actualName = ensureLoaded(item)
		if type(module) ~= 'table' then
			continue
		end
		local fn = module[queryName]
		if type(fn) == 'function' then
			count += 1
			b_modules[count], b_fns[count], b_names[count] = module, fn, actualName :: string
		end
	end
	return b_modules, b_fns, b_names, count
end

local function createRunner(b_modules: { any }, b_fns: { any }, b_names: { string }, count: number, passSelf: boolean)
	return function(...)
		for i = 1, count do
			debug.setmemorycategory(b_names[i])
			if not passSelf then
				b_fns[i](...)
			else
				b_fns[i](b_modules[i], ...)
			end
		end
	end
end

local function internalDispatch(
	modules: { any },
	methodName: string,
	args: { any },
	mode: 'Sync' | 'Async' | 'Parallel'
): (LoadedModules, Errors?)
	local queryName, passSelf = parseMethodName(methodName)
	local modulesArray: LoadedModules = {}
	local errors: Errors = {}
	local errorSuffix = if mode == 'Sync' then '' else `({mode})`

	local function execute(item)
		local module, actualName = ensureLoaded(item, errors)
		if type(module) ~= 'table' then
			return
		end

		local fn = module[queryName]
		if type(fn) ~= 'function' then
			return
		end

		debug.setmemorycategory(actualName :: string)

		local success, err
		if passSelf then
			success, err = xpcall(fn, traceErrorHandler, module, unpack(args, 1, (args :: any).n))
		else
			success, err = xpcall(fn, traceErrorHandler, unpack(args, 1, (args :: any).n))
		end

		if success then
			table.insert(modulesArray, module)
		else
			errors[actualName :: string] = err.msg
			local suffixStr = errorSuffix ~= '' and ` {errorSuffix}` or ''
			nonFatalError('Error in %s:%s()%s\n%s', err.trace, actualName :: string, queryName, suffixStr, err.msg)
		end
	end

	if mode == 'Sync' then
		for _, item in modules do
			execute(item)
		end
	elseif mode == 'Async' then
		task.spawn(function()
			for _, item in modules do
				execute(item)
			end
		end)
	else
		for _, item in modules do
			task.spawn(execute, item)
		end
	end

	return modulesArray, next(errors) ~= nil and errors or nil
end

local function bindToRunService(
	modules: { LoadedModule | ModuleScript },
	eventName: string,
	methodName: string,
	override: (number | EnumItem)?
): Cleanup
	local queryName, passSelf = parseMethodName(methodName)
	local b_modules, b_fns, b_names, count = buildBatch(modules, queryName)

	if count == 0 then
		return function() end
	end

	local run = createRunner(b_modules, b_fns, b_names, count, passSelf)

	local task: Task
	if eventName == 'RenderStepped' then
		if type(override) == 'number' then
			batchCounter += 1
			local bindName = `Bootstrapper_RenderBatch_{batchCounter}_{queryName}`
			RunService:BindToRenderStep(bindName, override, run)
			task = function()
				RunService:UnbindFromRenderStep(bindName)
			end
		else
			task = RunService.RenderStepped:Connect(run)
		end
	elseif eventName == 'PreSimulation' and RunService.BindToSimulation then
		if typeof(override) == 'EnumItem' and (override :: EnumItem).EnumType == Enum.StepFrequency then
			task = (RunService :: any):BindToSimulation(run, override)
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

--[=[
	@class Bootstrapper
	A lightweight, agnostic scheduler and module loader for Roblox.
	Eliminate unpredictable load orders, race conditions, and event connections. 
	By organizing your codebase into a deterministic pipeline, 
	you know exactly what runs, and in what order, every single frame.
]=]
local Bootstrapper = {}

--[=[
	Creates a predicate function that matches a module's name against a string.
	@function byName
	@within Bootstrapper
	@param matchName string -- The string pattern to match against the module's name.
	@return Predicate
]=]
function Bootstrapper.byName(matchName: string): Predicate
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
	@param predicate: Predicate? -- Optional filter to include specific modules (e.g., Bootstrapper.byName("Service$")).
	@return LoadedModules, Errors?
]=]
function Bootstrapper.loadChildren(parent: Instance, predicate: Predicate?): (LoadedModules, Errors?)
	return loadFromInstances(parent:GetChildren(), predicate)
end

--[=[
	Requires all descendant ModuleScripts within a given parent.
	Returns an array of loaded modules to guarantee order execution.
	@yields
	@function loadDescendants
	@within Bootstrapper
	@param parent Instance -- The Instance to search within.
	@param predicate: Predicate? -- Optional filter to include specific modules (e.g., Bootstrapper.byName("Service$")).
	@return LoadedModules, Errors?
]=]
function Bootstrapper.loadDescendants(parent: Instance, predicate: Predicate?): (LoadedModules, Errors?)
	return loadFromInstances(parent:GetDescendants(), predicate)
end

--[=[
	Requires specific modules in a guaranteed sequence array.
	@yields
	@function loadSequence
	@within Bootstrapper
	@param modules ModuleScripts -- Array of ModuleScripts.
	@param predicate: Predicate? -- Optional filter to include specific modules (e.g., Bootstrapper.byName("Service$")).
	@return LoadedModules, Errors?
]=]
function Bootstrapper.loadSequence(modules: ModuleScripts, predicate: Predicate?): (LoadedModules, Errors?)
	return loadFromInstances((modules :: any) :: { Instance }, predicate)
end

--[=[
	Executes methods one-by-one and yields the caller until complete.
	Guarantees that Module A is finished before Module B starts.
	@yields
	@function run
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts.
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@param ... any -- Additional arguments to pass to the method.
	@return LoadedModules, Errors?
]=]
function Bootstrapper.run(
	modules: LoadedModules | ModuleScripts,
	methodName: string,
	...: any
): (LoadedModules, Errors?)
	return internalDispatch(modules :: { any }, methodName, table.pack(...), 'Sync')
end

--[=[
	Executes methods one-by-one in a new thread.
	Maintains order but does not block the calling script.
	@function runAsync
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts.
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.runAsync(modules: LoadedModules | ModuleScripts, methodName: string, ...: any): ()
	internalDispatch(modules :: { any }, methodName, table.pack(...), 'Async')
end

--[=[
	Executes all methods simultaneously using multiple threads.
	Fastest execution, but order of completion is not guaranteed.
	@function runParallel
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts.
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@param ... any -- Additional arguments to pass to the method.
]=]
function Bootstrapper.runParallel(modules: LoadedModules | ModuleScripts, methodName: string, ...: any): ()
	internalDispatch(modules :: { any }, methodName, table.pack(...), 'Parallel')
end

--[=[
	Binds a method across all modules to an RBXScriptSignal, a custom Signal, or a subscription function.
	@function bindTo
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts.
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@param event Event -- An RBXScriptSignal, custom Signal or a subscription function.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindTo(modules: LoadedModules | ModuleScripts, methodName: string, event: Event): Cleanup
	local queryName, passSelf = parseMethodName(methodName)
	local b_modules, b_fns, b_names, count = buildBatch(modules, queryName)

	if count == 0 then
		return function() end
	end

	local run = createRunner(b_modules, b_fns, b_names, count, passSelf)
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
	@param modules LoadedModules | ModuleScripts -- The collection to bind.
	@param methodName string -- The method to execute. Supports '.' and ':' notation.
	@param interval number -- Time in seconds between executions.
	@param signal RBXScriptSignal? -- Optional signal to hook (defaults to Heartbeat). RenderStepped is not allowed.
	@return Cleanup -- A function to stop the interval.
]=]
function Bootstrapper.bindToInterval(
	modules: LoadedModules | ModuleScripts,
	methodName: string,
	interval: number,
	signal: RBXScriptSignal?
): Cleanup
	assert(interval > 0, `[Bootstrapper] interval must be greater than 0; got {interval}`)
	assert(
		signal ~= RunService.Stepped,
		'[Bootstrapper] bindToInterval cannot be used with Stepped. Use PreSimulation instead.'
	)

	local queryName, passSelf = parseMethodName(methodName)
	local b_modules, b_fns, b_names, count = buildBatch(modules, queryName)

	if count == 0 then
		return function() end
	end

	local run = createRunner(b_modules, b_fns, b_names, count, passSelf)
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
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToHeartbeat(modules: LoadedModules | ModuleScripts, methodName: string): Cleanup
	return bindToRunService(modules, 'Heartbeat', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.RenderStepped` 
	or `RunService:BindToRenderStep` if a priority is given.
	@client
	@function bindToRenderStep
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@param priority number? -- Optional execution priority. If provided, uses BindToRenderStep instead of RenderStepped.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToRenderStep(
	modules: LoadedModules | ModuleScripts,
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
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@param frequency Enum.StepFrequency? -- Optional execution frequency. If provided, uses BindToSimulation instead of PreSimulation.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPreSimulation(
	modules: LoadedModules | ModuleScripts,
	methodName: string,
	frequency: Enum.StepFrequency?
): Cleanup
	return bindToRunService(modules, 'PreSimulation', methodName, frequency)
end

--[=[
	Hooks a specified method in all modules to `RunService.PostSimulation`.
	@function bindToPostSimulation
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPostSimulation(modules: LoadedModules | ModuleScripts, methodName: string): Cleanup
	return bindToRunService(modules, 'PostSimulation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreAnimation`.
	@function bindToPreAnimation
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPreAnimation(modules: LoadedModules | ModuleScripts, methodName: string): Cleanup
	return bindToRunService(modules, 'PreAnimation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreRender`.
	@client
	@function bindToPreRender
	@within Bootstrapper
	@param modules LoadedModules | ModuleScripts -- The array of loaded modules or ModuleScripts
	@param methodName string -- The method to execute. Prefix with '.' for static calls or ':' for object methods.
	@return Cleanup -- A cleanup function to disconnect the event.
]=]
function Bootstrapper.bindToPreRender(modules: LoadedModules | ModuleScripts, methodName: string): Cleanup
	assert(RunService:IsClient(), '[Bootstrapper] bindToPreRender can only be called on the Client.')
	return bindToRunService(modules, 'PreRender', methodName)
end

return Bootstrapper
