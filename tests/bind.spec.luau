local Roblox = require('./roblox')
local Test = require('./test')

local test, expect = Test.test, Test.expect
local folder, module = Roblox.folder, Roblox.module

local function recorder(log, name)
	return {
		Update = function(self, ...)
			table.insert(log, { name, self, ... })
		end,
	}
end

test('bindTo calls the method in order on every fire and stops after cleanup', function()
	local log = {}
	local a, b = recorder(log, 'A'), recorder(log, 'B')
	local signal = Roblox.signal()

	local cleanup = Roblox.new().Bootstrapper.bindTo({ a, {}, b }, 'Update', signal)
	signal:Fire(1, 2)
	signal:Fire(3)
	cleanup()
	signal:Fire(4)
	expect(log).toEqual({ { 'A', a, 1, 2 }, { 'B', b, 1, 2 }, { 'A', a, 3 }, { 'B', b, 3 } })
end)

test('bindTo calls without self when prefixed with .', function()
	local received
	local signal = Roblox.signal()
	Roblox.new().Bootstrapper.bindTo({
		{
			Update = function(...)
				received = { select('#', ...), ... }
			end,
		},
	}, '.Update', signal)

	signal:Fire(1)
	expect(received).toEqual({ 1, 1 })
end)

test('bindTo accepts lowercase connect and subscription functions', function()
	local log = {}
	local callbacks, destroyed = {}, false
	local custom = {
		connect = function(_, callback)
			table.insert(callbacks, callback)
			return {
				Destroy = function()
					destroyed = true
				end,
			}
		end,
	}

	local Bootstrapper = Roblox.new().Bootstrapper
	local cleanupCustom = Bootstrapper.bindTo({ recorder(log, 'A') }, 'Update', custom)
	local cleanedUp, part = false, Roblox.instance('Part', 'Part')
	local cleanupFunction = Bootstrapper.bindTo({ recorder(log, 'B') }, 'Update', function(callback)
		table.insert(callbacks, callback)
		return {
			function()
				cleanedUp = true
			end,
			part,
		}
	end)
	for _, callback in callbacks do
		callback()
	end
	cleanupCustom()
	cleanupFunction()
	expect(#log).toBe(2)
	expect(destroyed).toBe(true)
	expect(cleanedUp).toBe(true)
	expect(part.destroyed).toBe(true)
end)

test('bindTo does not connect when no module has the method', function()
	local signal = Roblox.signal()
	Roblox.new().Bootstrapper.bindTo({ {} }, 'Update', signal)
	expect(#signal.connections).toBe(0)
end)

test('a bound method that errors does not stop the others', function()
	local log = {}
	local group = folder('Group', {
		module('Broken', {
			Update = function()
				error('update failed', 0)
			end,
		}),
	})
	local signal = Roblox.signal()

	local roblox = Roblox.new()
	roblox.Bootstrapper.bindTo({ recorder(log, 'A'), group, recorder(log, 'B') }, 'Update', signal)
	signal:Fire()
	expect(#log).toBe(2)
	expect(log[2][1]).toBe('B')
	expect(#roblox.errors).toBe(1)
	expect(roblox.errors[1]).toMatch('^%[Bootstrapper%] Error in Broken:Update%(%)\n    update failed')
end)

test('profiling labels every bound method and sets its memory category', function()
	local roblox = Roblox.new()
	local categories = {}
	local function categoryRecorder()
		return {
			Update = function()
				table.insert(categories, roblox.getMemoryCategory())
			end,
		}
	end
	local group = folder('Group', {
		module('A', categoryRecorder()),
		module('Broken', {
			Update = function()
				error('update failed', 0)
			end,
		}),
		module('C', categoryRecorder()),
	})
	local signal = Roblox.signal()

	roblox.Bootstrapper.bindTo({ group }, 'Update', signal)
	signal:Fire()
	expect(#roblox.profile).toBe(0)
	expect(categories).toEqual({ 'Default', 'Default' })

	categories = {}
	roblox.Bootstrapper.setProfiling(true)
	roblox.setMemoryCategory('Caller')
	signal:Fire()
	expect(roblox.profile).toEqual({ 'begin A:Update', 'end', 'begin Broken:Update', 'end', 'begin C:Update', 'end' })
	expect(categories).toEqual({ 'A', 'C' })
	expect(roblox.getMemoryCategory()).toBe('Caller')
end)

test('bindToInterval fires once per interval with the time since the last call until cleanup', function()
	local times = {}
	local roblox = Roblox.new()
	local cleanup = roblox.Bootstrapper.bindToInterval({
		{
			Update = function(_, dt)
				table.insert(times, dt)
			end,
		},
	}, 'Update', 1)

	for _, clock in { 0.5, 1.25, 1.5, 2, 5.5, 5.75, 6 } do
		roblox.clock = clock
		roblox.RunService.Heartbeat:Fire()
	end
	cleanup()
	roblox.clock = 10
	roblox.RunService.Heartbeat:Fire()
	expect(times).toEqual({ 1.25, 0.75, 3.5, 0.5 })
end)

test('bindToInterval uses the given signal and rejects invalid arguments', function()
	local roblox = Roblox.new()
	local signal = Roblox.signal()
	local modules = { recorder({}, 'A') }

	roblox.Bootstrapper.bindToInterval(modules, 'Update', 1, signal)
	expect(#signal.connections).toBe(1)
	expect(function()
		roblox.Bootstrapper.bindToInterval(modules, 'Update', 0)
	end).toThrow('interval must be greater than 0')
	expect(function()
		roblox.Bootstrapper.bindToInterval(modules, 'Update', 1, roblox.RunService.Stepped)
	end).toThrow('cannot be used with Stepped')
end)

test('event binds connect to the matching RunService event', function()
	local roblox = Roblox.new()
	for _, event in { 'Heartbeat', 'PreSimulation', 'PostSimulation', 'PreAnimation', 'PreRender' } do
		local log = {}
		local cleanup = roblox.Bootstrapper[`bindTo{event}`]({ recorder(log, event) }, 'Update')
		roblox.RunService[event]:Fire(0.5)
		cleanup()
		roblox.RunService[event]:Fire(0.5)
		expect(#log).toBe(1)
		expect(log[1][3]).toBe(0.5)
	end
end)

test('bindToSimulation and bindToAnimation pass the frequency and priority', function()
	local roblox = Roblox.new()
	for _, name in { 'Simulation', 'Animation' } do
		local log = {}
		local signal = roblox.RunService[`{name:lower()}Signal`]
		local cleanup = roblox.Bootstrapper[`bindTo{name}`]({ recorder(log, name) }, 'Update', 'Hz60', 100)
		signal:Fire(1 / 60)
		cleanup()
		signal:Fire(1 / 60)
		expect(roblox.RunService[`{name:lower()}Args`]).toEqual({ 'Hz60', 100 })
		expect(#log).toBe(1)
	end
end)

test('bindToRenderStep binds with a unique name and priority', function()
	local log = {}
	local roblox = Roblox.new()
	local renderSteps = roblox.RunService.renderSteps

	local cleanupA = roblox.Bootstrapper.bindToRenderStep({ recorder(log, 'A') }, ':Update', 200)
	roblox.Bootstrapper.bindToRenderStep({ recorder(log, 'B') }, ':Update', 300)
	local stepA = renderSteps.Bootstrapper_RenderBatch_1_Update
	expect(stepA.priority).toBe(200)
	expect(renderSteps.Bootstrapper_RenderBatch_2_Update.priority).toBe(300)

	stepA.callback(0.1)
	expect(log[1][3]).toBe(0.1)
	cleanupA()
	expect(renderSteps.Bootstrapper_RenderBatch_1_Update).toBe(nil)
	expect(function()
		roblox.Bootstrapper.bindToRenderStep({}, 'Update', nil)
	end).toThrow('requires a priority')
end)

test('client binds cannot be used on the server', function()
	local roblox = Roblox.new()
	roblox.isClient = false
	expect(function()
		roblox.Bootstrapper.bindToRenderStep({}, 'Update', 200)
	end).toThrow('can only be called on the Client')
	expect(function()
		roblox.Bootstrapper.bindToPreRender({}, 'Update')
	end).toThrow('can only be called on the Client')
end)
