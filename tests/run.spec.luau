local task = require('@lune/task')

local Roblox = require('./roblox')
local Test = require('./test')

local test, expect = Test.test, Test.expect
local folder, module = Roblox.folder, Roblox.module

-- A module whose Init logs when it starts and ends, yielding for `seconds` in between
local function logger(log, name, seconds)
	return {
		Init = function()
			table.insert(log, `{name} start`)
			if seconds then
				task.wait(seconds)
			end
			table.insert(log, `{name} end`)
		end,
	}
end

test('run passes self only without the . prefix', function()
	local received = {}
	local loaded = {
		Init = function(...)
			table.insert(received, { select('#', ...), ... })
		end,
	}

	local Bootstrapper = Roblox.new().Bootstrapper
	Bootstrapper.run({ loaded }, ':Init', 1, nil, 3)
	Bootstrapper.run({ loaded }, 'Init', 1)
	Bootstrapper.run({ loaded }, '.Init', 1, nil, 3)
	expect(received).toEqual({
		{ 4, loaded, 1, nil, 3 },
		{ 2, loaded, 1 },
		{ 3, 1, nil, 3 },
	})
	expect(received[1][2]).toBe(loaded)
end)

test('run finishes each module before starting the next', function()
	local log = {}
	local roblox = Roblox.new()
	roblox.Bootstrapper.run({ logger(log, 'A', 0.02), logger(log, 'B', 0.01) }, 'Init')
	expect(log).toEqual({ 'A start', 'A end', 'B start', 'B end' })
	expect(#roblox.warnings).toBe(0)
end)

test('run keeps modules without the method and drops modules whose method errored', function()
	local plain = {}
	local working = { Init = function() end }
	local group = folder('Group', {
		module('Broken', {
			Init = function()
				error('init failed', 0)
			end,
		}),
	})

	local roblox = Roblox.new()
	local broken = roblox.Bootstrapper.load({ group })[1]
	local modules, errors = roblox.Bootstrapper.run({ plain, broken, working }, 'Init')
	expect(#modules).toBe(2)
	expect(modules[1]).toBe(plain)
	expect(modules[2]).toBe(working)
	expect(errors).toEqual({ ['Group.Broken'] = 'init failed' })
	expect(roblox.errors[1]).toMatch(
		'^%[Bootstrapper%] Error in Broken:Init%(%)\n    init failed\n    %-%-%-%- Stack trace'
	)
end)

test('run treats a strict module that errors on unknown keys as having no method', function()
	local strict = setmetatable({}, {
		__index = function(_, key)
			error(`{key} is not a valid member`)
		end,
	})

	local roblox = Roblox.new()
	local modules, errors = roblox.Bootstrapper.run({ strict }, 'Init')
	expect(modules[1]).toBe(strict)
	expect(errors).toBe(nil)
	expect(#roblox.errors).toBe(0)
end)

test('run sets the memory category to the module name and restores the caller category', function()
	local roblox = Roblox.new()
	local category
	local group = folder('Group', {
		module('Inventory', {
			Init = function()
				category = roblox.getMemoryCategory()
			end,
		}),
	})

	roblox.setMemoryCategory('Caller')
	roblox.Bootstrapper.run({ group }, 'Init')
	expect(category).toBe('Inventory')
	expect(roblox.getMemoryCategory()).toBe('Caller')
end)

test('run warns with full names when a method is still yielding', function()
	local roblox = Roblox.new()
	roblox.delayScale = 0.001
	local group = folder('Group', { module('Slow', logger({}, 'Slow', 0.1)) })

	roblox.Bootstrapper.run({ group }, 'Init')
	expect(roblox.warnings).toEqual({
		"[Bootstrapper] Infinite yield possible: 'Init' is still running in Group.Slow. Use spawn() or spawnConcurrent() for methods that never return.",
	})
end)

test('runConcurrent warns only about the methods still yielding', function()
	local roblox = Roblox.new()
	roblox.delayScale = 0.001
	local group = folder('Group', {
		module('Fast', logger({}, 'Fast', 0.001)),
		module('Slow', logger({}, 'Slow', 0.1)),
		module('Slower', logger({}, 'Slower', 0.1)),
	})

	roblox.Bootstrapper.runConcurrent({ group }, 'Init')
	expect(#roblox.warnings).toBe(1)
	expect(roblox.warnings[1]).toMatch("'Init' is still running in Group%.Slow, Group%.Slower%.")
end)

test('run does not warn when methods finish in time', function()
	local roblox = Roblox.new()
	roblox.delayScale = 0.001
	roblox.Bootstrapper.run({ logger({}, 'Fast') }, 'Init')
	task.wait(0.05)
	expect(#roblox.warnings).toBe(0)
end)

test('runConcurrent starts in order, waits for all and keeps the original order', function()
	local log = {}
	local slow, fast = logger(log, 'Slow', 0.05), logger(log, 'Fast', 0.01)

	local modules = Roblox.new().Bootstrapper.runConcurrent({ slow, fast }, 'Init')
	expect(log).toEqual({ 'Slow start', 'Fast start', 'Fast end', 'Slow end' })
	expect(modules[1]).toBe(slow)
	expect(modules[2]).toBe(fast)
end)

test('runConcurrent does not yield when no method yields', function()
	local log = {}
	local Bootstrapper = Roblox.new().Bootstrapper
	local thread = coroutine.create(function()
		Bootstrapper.runConcurrent({ logger(log, 'A'), logger(log, 'B') }, 'Init')
	end)

	coroutine.resume(thread)
	expect(coroutine.status(thread)).toBe('dead')
	expect(log).toEqual({ 'A start', 'A end', 'B start', 'B end' })
end)

test('runConcurrent finishes when a module fails to load or errors', function()
	local log = {}
	local broken = {
		Init = function()
			error('init failed', 0)
		end,
	}

	local roblox = Roblox.new()
	local modules, errors = roblox.Bootstrapper.runConcurrent({ 'Missing', broken, logger(log, 'Slow', 0.01) }, 'Init')
	expect(#modules).toBe(1)
	expect(log).toEqual({ 'Slow start', 'Slow end' })
	expect(errors and errors.UnknownModule).toMatch('got string')
	expect(errors and errors['UnknownModule (2)']).toBe('init failed')
end)

test('spawn returns at once and keeps the order', function()
	local log = {}
	Roblox.new().Bootstrapper.spawn({ logger(log, 'A', 0.01), logger(log, 'B') }, 'Init')
	expect(log).toEqual({ 'A start' })
	task.wait(0.1)
	expect(log).toEqual({ 'A start', 'A end', 'B start', 'B end' })
end)

test('spawnConcurrent starts every method at once without yielding', function()
	local log = {}
	Roblox.new().Bootstrapper.spawnConcurrent({ logger(log, 'A', 0.01), logger(log, 'B', 0.01) }, 'Init')
	expect(log).toEqual({ 'A start', 'B start' })
	task.wait(0.1)
	expect(#log).toBe(4)
end)
