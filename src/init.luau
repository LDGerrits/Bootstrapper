--!strict
--!nolint LocalUnused
--!nolint LocalShadow

local RunService = game:GetService('RunService')

local injectSelfRegistry = setmetatable({}, { __mode = 'k' })

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

local Bootstrapper = {}

local function shouldInjectSelf(module: any): boolean
	local registered = injectSelfRegistry[module]
	if registered ~= nil then
		return registered
	end
	return true
end

--[=[
	Creates a predicate function that matches a module's name against a string.
	@param matchName The string pattern to match against the module's name.
	@return A predicate function that can be passed to loadDescendants.
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
	@param parent The Instance to search within.
	@param predicate An optional function to filter which modules are loaded.
	@param useSelf If true (default), methods on these modules will be passed 'self'.
	@return A dictionary map of module names to their required return values.
]=]
function Bootstrapper.loadChildren(parent: Instance, predicate: Predicate?, useSelf: boolean?): Modules
	local modules = {}
	local shouldInject = useSelf ~= false

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
	@param parent The Instance to search within.
	@param predicate An optional function to filter which modules are loaded.
	@param useSelf boolean? -- If true (default), methods on these modules will be passed 'self'.
	@return A dictionary map of module names to their required return values.
]=]
function Bootstrapper.loadDescendants(parent: Instance, predicate: Predicate?, useSelf: boolean?): Modules
	local modules = {}
	local shouldInject = useSelf ~= false

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
		return
	end

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

				done += 1
				if done == total then
					task.spawn(mainThread)
				end
			end
			task.spawn(wrapper, ...)
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

local function doCleanup(task: Task): ()
	if typeof(task) == 'Instance' then
		task:Destroy()
	elseif typeof(task) == 'RBXScriptConnection' then
		task:Disconnect()
	elseif typeof(task) == 'function' then
		task()
	elseif typeof(task) == 'table' then
		local task = (task :: any) :: {
			Destroy: (...unknown) -> ...unknown?,
			destroy: (...unknown) -> ...unknown?,
			Disconnect: (...unknown) -> ...unknown?,
			disconnect: (...unknown) -> ...unknown?,
		}

		if typeof(task.destroy) == 'function' then
			local task = (task :: any) :: { destroy: (...unknown) -> ...unknown }
			task:destroy()
		elseif typeof(task.Destroy) == 'function' then
			local task = (task :: any) :: { Destroy: (...unknown) -> ...unknown }
			task:Destroy()
		elseif typeof(task.Disconnect) == 'function' then
			local task = (task :: any) :: { Disconnect: (...unknown) -> ...unknown }
			task:Disconnect()
		elseif typeof(task.disconnect) == 'function' then
			local task = (task :: any) :: { disconnect: (...unknown) -> ...unknown }
			task:disconnect()
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

local function bindToRunService(modules: Modules, eventName: string, methodName: string): () -> ()
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
			local priority = module[`{methodName}Priority`]
				or module.Priority
				or module.priority
				or module.RenderPriority
				or module.renderPriority
			if type(priority) == 'number' then
				local bindName = `{name}_{methodName}`
				RunService:BindToRenderStep(bindName, priority, run)
				table.insert(tasks, function()
					RunService:UnbindFromRenderStep(bindName)
				end)
			else
				table.insert(tasks, RunService.PreRender:Connect(run))
			end
		elseif eventName == 'PreSimulation' and RunService.BindToSimulation then
			local freq = module[`{methodName}Frequency`]
				or module.Frequency
				or module.frequency
				or module.StepFrequency
				or module.stepFrequency
			if typeof(freq) == 'EnumItem' and (freq :: EnumItem).EnumType == Enum.StepFrequency then
				table.insert(tasks, (RunService :: any):BindToSimulation(run, freq))
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
	Hooks a specified method in all modules to `RunService.Heartbeat`.
	
	@function heartbeat
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param methodName string -- The method to execute every Heartbeat frame.
	@return Cleanup -- A function to disconnect the bound loops.
]=]
function Bootstrapper.heartbeat(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'Heartbeat', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.RenderStepped` (Client-side only).
	Searches for `{methodName}Priority` or `Priority` on the module to use with `BindToRenderStep`.
	
	@function renderStepped
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param methodName string -- The method to execute prior to frame render.
	@return Cleanup -- A function to unbind/disconnect the bound loops.
]=]
function Bootstrapper.renderStepped(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'RenderStepped', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreSimulation`. 
	Searches for `{methodName}Frequency` or `Frequency` (`Enum.StepFrequency`) on the module to use with `BindToSimulation`.
	
	@function preSimulation
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param methodName string -- The method to execute prior to physics simulation.
	@return Cleanup -- A function to disconnect the bound loops.
]=]
function Bootstrapper.preSimulation(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'PreSimulation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PostSimulation`.
	
	@function postSimulation
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param methodName string -- The method to execute after physics simulation.
	@return Cleanup -- A function to disconnect the bound loops.
]=]
function Bootstrapper.postSimulation(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'PostSimulation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreAnimation`.
	
	@function preAnimation
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param methodName string -- The method to execute prior to animation updates.
	@return Cleanup -- A function to disconnect the bound loops.
]=]
function Bootstrapper.preAnimation(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'PreAnimation', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.PreRender`.
	
	@function preRender
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param methodName string -- The method to execute prior to rendering.
	@return Cleanup -- A function to disconnect the bound loops.
]=]
function Bootstrapper.preRender(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'PreRender', methodName)
end

--[=[
	Hooks a specified method in all modules to `RunService.Stepped` (Legacy).
	
	@function stepped
	@within Bootstrapper
	@param modules Modules -- The dictionary of loaded modules.
	@param methodName string -- The method to execute.
	@return Cleanup -- A function to disconnect the bound loops.
]=]
function Bootstrapper.stepped(modules: Modules, methodName: string): Cleanup
	return bindToRunService(modules, 'Stepped', methodName)
end

return Bootstrapper
