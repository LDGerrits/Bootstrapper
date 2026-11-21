local fs = require('@lune/fs')
local luau = require('@lune/luau')
local task = require('@lune/task')

local SOURCE = fs.readFile('src/init.luau')

local Roblox = {}

local Instance = {}
Instance.__index = Instance

function Instance:IsA(className)
	return self.ClassName == className
end

function Instance:GetChildren()
	return table.clone(self.children)
end

function Instance:GetDescendants()
	local descendants = {}
	for _, child in self.children do
		table.insert(descendants, child)
		for _, descendant in child:GetDescendants() do
			table.insert(descendants, descendant)
		end
	end
	return descendants
end

function Instance:GetFullName()
	return if self.Parent then `{self.Parent:GetFullName()}.{self.Name}` else self.Name
end

function Instance:Destroy()
	self.destroyed = true
end

-- Instances are userdata, like in Roblox
function Roblox.instance(className, name, children)
	local instance = newproxy(true)
	local metatable = getmetatable(instance)
	metatable.__index = setmetatable({ ClassName = className, Name = name, children = children or {} }, Instance)
	metatable.__newindex = metatable.__index
	metatable.__type = 'Instance'
	metatable.__tostring = function()
		return name
	end
	for _, child in instance.children do
		child.Parent = instance
	end
	return instance
end

function Roblox.folder(name, children)
	return Roblox.instance('Folder', name, children)
end

function Roblox.module(name, value)
	local moduleScript = Roblox.instance('ModuleScript', name)
	moduleScript.load = if type(value) == 'function'
		then value
		else function()
			return value
		end
	return moduleScript
end

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	local index = table.find(self.signal.connections, self)
	if index then
		table.remove(self.signal.connections, index)
	end
end

local Signal = {}
Signal.__index = Signal

function Roblox.signal()
	return setmetatable({ connections = {} }, Signal)
end

function Signal:Connect(callback)
	local connection = setmetatable({ signal = self, callback = callback }, Connection)
	table.insert(self.connections, connection)
	return connection
end

function Signal:Fire(...)
	for _, connection in table.clone(self.connections) do
		connection.callback(...)
	end
end

local function createRunService(context)
	local RunService = Roblox.instance('RunService', 'Run Service')
	for _, name in { 'Heartbeat', 'Stepped', 'PreSimulation', 'PostSimulation', 'PreAnimation', 'PreRender' } do
		RunService[name] = Roblox.signal()
	end
	RunService.simulationSignal = Roblox.signal()
	RunService.animationSignal = Roblox.signal()
	RunService.renderSteps = {}

	function RunService:IsClient()
		return context.isClient
	end

	function RunService:BindToRenderStep(name, priority, callback)
		self.renderSteps[name] = { priority = priority, callback = callback }
	end

	function RunService:UnbindFromRenderStep(name)
		self.renderSteps[name] = nil
	end

	function RunService:BindToSimulation(callback, frequency, priority)
		self.simulationArgs = { frequency, priority }
		return self.simulationSignal:Connect(callback)
	end

	function RunService:BindToAnimation(callback, frequency, priority)
		self.animationArgs = { frequency, priority }
		return self.animationSignal:Connect(callback)
	end

	return RunService
end

function Roblox.new()
	local context = {
		isClient = true,
		clock = 0,
		delayScale = 1,
		errors = {},
		warnings = {},
		profile = {},
	}
	local RunService = createRunService(context)
	context.RunService = RunService

	local categories = setmetatable({}, { __mode = 'k' })
	function context.getMemoryCategory()
		return categories[coroutine.running()] or 'Default'
	end
	function context.setMemoryCategory(category)
		categories[coroutine.running()] = category
	end

	local environment = {
		typeof = function(value)
			return if type(value) == 'userdata' then getmetatable(value).__type else typeof(value)
		end,
		game = {
			GetService = function(_, name)
				assert(name == 'RunService', `Unexpected service {name}`)
				return RunService
			end,
		},
		require = function(moduleScript)
			assert(moduleScript.ClassName == 'ModuleScript', 'Attempted to call require with invalid argument(s).')
			if not moduleScript.required then
				moduleScript.required = true
				moduleScript.success, moduleScript.result = pcall(moduleScript.load)
			end
			if not moduleScript.success then
				error(moduleScript.result, 0)
			end
			return moduleScript.result
		end,
		warn = function(...)
			table.insert(context.warnings, table.concat({ ... }, ' '))
		end,
		task = setmetatable({
			spawn = function(callback, ...)
				if callback == error then
					table.insert(context.errors, (...))
					return nil
				end
				return task.spawn(callback, ...)
			end,
			delay = function(seconds, ...)
				return task.delay(seconds * context.delayScale, ...)
			end,
		}, { __index = task }),
		os = setmetatable({
			clock = function()
				return context.clock
			end,
		}, { __index = os }),
		debug = setmetatable({
			getmemorycategory = context.getMemoryCategory,
			setmemorycategory = context.setMemoryCategory,
			profilebegin = function(label)
				table.insert(context.profile, `begin {label}`)
			end,
			profileend = function()
				table.insert(context.profile, 'end')
			end,
		}, { __index = debug }),
	}

	context.Bootstrapper = luau.load(SOURCE, { debugName = 'Bootstrapper', environment = environment })()
	return context
end

return Roblox
