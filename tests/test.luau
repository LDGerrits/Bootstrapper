local task = require('@lune/task')

local TIMEOUT = 5

local tests = {}

-- Only formats two levels deep, as instances refer to each other
local function format(value, depth: number?)
	local level = depth or 0
	if type(value) == 'string' then
		return `'{value}'`
	elseif type(value) == 'table' and level < 2 then
		local parts = {}
		for key, item in value do
			table.insert(parts, `{format(key, level + 1)}: {format(item, level + 1)}`)
		end
		table.sort(parts)
		return `\{{table.concat(parts, ', ')}}`
	end
	return tostring(value)
end

local function deepEqual(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function expect(actual)
	local function check(passed, message)
		if not passed then
			error(message, 3)
		end
	end

	return {
		toBe = function(expected)
			check(actual == expected, `Expected {format(expected)}, got {format(actual)}`)
		end,
		toEqual = function(expected)
			check(deepEqual(actual, expected), `Expected {format(expected)}, got {format(actual)}`)
		end,
		toMatch = function(pattern)
			check(
				type(actual) == 'string' and actual:find(pattern) ~= nil,
				`Expected {format(actual)} to match '{pattern}'`
			)
		end,
		toThrow = function(text)
			local success, err = pcall(actual)
			check(not success, 'Expected function to throw')
			check(tostring(err):find(text, 1, true) ~= nil, `Expected error {format(err)} to contain '{text}'`)
		end,
	}
end

local function test(name: string, callback: () -> ())
	table.insert(tests, { name = name, callback = callback })
end

-- Runs each test in its own thread so a test that never finishes times out instead of hanging
local function run(): number
	local failures = 0
	for _, entry in tests do
		local done, success, err = false, false, nil
		task.spawn(function()
			success, err = xpcall(entry.callback, debug.traceback)
			done = true
		end)

		local startTime = os.clock()
		while not done and os.clock() - startTime < TIMEOUT do
			task.wait()
		end
		if not done then
			success, err = false, `Timed out after {TIMEOUT} seconds`
		end

		if success then
			print(`PASS  {entry.name}`)
		else
			failures += 1
			print(`FAIL  {entry.name}\n      {tostring(err):gsub('\n', '\n      ')}`)
		end
	end
	print(`\n{#tests - failures} passed, {failures} failed`)
	return failures
end

return {
	test = test,
	expect = expect,
	run = run,
}
