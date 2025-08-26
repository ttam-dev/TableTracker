--!strict
--!optimize 2
-- TableTracker.lua
-- @mzqrbxabw587 - 26/08/2025

local TableTracker = {}

--// Types

type TrackedTable = {
	__isProxy: boolean,
	__raw: { any },
	__path: { any },
	__onChange: (path: { any }, oldValue: any, newValue: any, tableRef: { any }) -> (),
}

--// Helper functions

local function tableLength(t: { any }): number
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

local function clonePath(base, key)
	local newPath = { table.unpack(base) }
	if key ~= nil then
		table.insert(newPath, key)
	end
	return newPath
end

local function unwrap(value): any
	if type(value) ~= "table" then
		return value
	end
	local mt = getmetatable(value)
	if mt and mt.__isProxy then
		value = mt.__raw -- grab the raw inner table
	end

	local result = {}
	for k, sub in pairs(value) do
		result[k] = unwrap(sub)
	end
	return result
end

local function isTracked(value): (boolean, TrackedTable?)
	if type(value) ~= "table" then
		return false
	end
	local mt = getmetatable(value)
	return mt and mt.__isProxy ~= nil, mt
end

local function deepCopy(t: { any }): { any }
	local tCopy = table.clone(t)
	for k, v in pairs(t) do
		if type(v) == "table" then
			tCopy[k] = deepCopy(v)
		end
	end
	return tCopy
end

local function deepFreeze(t: { any }): { any }
	for k, v in pairs(t) do
		if type(v) == "table" then
			t[k] = deepFreeze(v)
		end
	end
	return table.freeze(t)
end

--// Main functionality

-- wraps a table in a proxy that tracks changes and calls onChange with the path, old value, new value, and raw table reference
function TableTracker.track(
	tbl: { any },
	onChange: (path: { any }, oldValue: any, newValue: any, tableRef: { any }) -> (),
	path: { any }?
): any
	assert(type(tbl) == "table", "TableTracker.track expects a table as the first argument")
	assert(type(onChange) == "function", "TableTracker.track expects a function as the second argument")
	path = path or {}

	local function wrap(inner: any, currentPath)
		if type(inner) ~= "table" then
			return inner
		end

		-- If it's already a proxy created by us, return it (avoid double-wrap)
		local existingMt = getmetatable(inner)
		if existingMt and existingMt.__isProxy then
			return inner
		end

		local proxy = {}
		local mt = {
			__isProxy = true,
			__raw = inner,
			__path = currentPath,
			__onChange = onChange,
			__index = function(_, key)
				return wrap(inner[key], clonePath(currentPath, key))
			end,
			__newindex = function(_, key, value)
				local old = inner[key]
				local rawValue = unwrap(value)

				-- avoid firing if nothing changes
				if old == rawValue then
					return
				end

				inner[key] = rawValue
				if onChange then
					onChange(clonePath(currentPath, key), old, rawValue, inner)
				end
			end,
			__tostring = function()
				return "[TrackedTable]"
			end,
		}
		return setmetatable(proxy, mt)
	end

	return wrap(tbl, path :: { any })
end

-- custom pairs for tracked tables
function TableTracker.pairs(t): ((nil, number?) -> (any, any)?, any, any)
	local ok, mt = isTracked(t)
	assert(ok and mt, "TableTracker.pairs expects a tracked table")

	local inner = mt.__raw

	return function(_, k)
		local nk, nv = next(inner, k)
		if nk == nil then
			return nil
		end
		-- wrap subtables so iteration is consistent
		if type(nv) == "table" then
			--nv = TableTracker.track(nv, onChange, clonePath(basePath, nk))
			nv = t[nk]
		end
		return nk, nv
	end,
		t,
		nil
end

-- custom ipairs for tracked tables
function TableTracker.ipairs(t): (() -> (number, any)?, any, any)
	local ok, mt = isTracked(t)
	assert(ok and mt, "TableTracker.ipairs expects a tracked table")

	local inner = mt.__raw

	local i = 0
	return function()
		i = i + 1
		local v = inner[i]
		if v ~= nil then
			if type(v) == "table" then
				--v = TableTracker.track(v, onChange, clonePath(basePath, i))
				v = t[i]
			end
			return i, v
		end
		return nil :: any
	end,
		t,
		nil
end

-- performs a deep update at the specified path, creating intermediate tables as needed
function TableTracker.deepUpdate(tbl, path, newValue): ()
	assert(tbl and type(tbl) == "table", "TableTracker.deepUpdate expects a table as the first argument")
	assert(type(path) == "table", "TableTracker.deepUpdate expects a table as the second argument")
	assert(#path > 0, "TableTracker.deepUpdate expects a non-empty path")

	local current = tbl
	for i = 1, #path - 1 do
		local key = path[i]
		if type(current[key]) ~= "table" then
			current[key] = {}
		end
		current = current[key]
	end
	local lastKey = path[#path]
	if lastKey ~= nil then
		current[lastKey] = unwrap(newValue)
	end
end

-- clears all keys from the table
function TableTracker.clear(t): ()
	local ok, mt = isTracked(t)
	assert(ok and mt, "TableTracker.clear expects a tracked table")

	local inner = mt.__raw
	for k in pairs(inner) do
		t[k] = nil
	end
end

-- returns the index of the first occurrence of value in the array portion of the table, or nil if not found
function TableTracker.find(t, value: any): number?
	local ok, mt = isTracked(t)
	assert(ok and mt, "TableTracker.find expects a tracked table")
	assert(value ~= nil, "TableTracker.find expects a non-nil value as the second argument")

	local inner = mt.__raw
	for i, v in ipairs(inner) do
		if v == value then
			return i
		end
	end
	return nil
end

-- returns a deep-frozen copy of the raw inner table
function TableTracker.getRaw(t): { any }
	local ok, mt = isTracked(t)
	assert(ok and mt, "TableTracker.getRaw expects a tracked table")

	return deepFreeze(deepCopy(mt.__raw)) -- return a frozen copy to prevent external mutation
end

-- inserts value at position pos (or at the end if pos is nil)
function TableTracker.insert(t, pos, value)
	assert(isTracked(t), "TableTracker.insert expects a tracked table")
	assert(value ~= nil or pos ~= nil, "TableTracker.insert expects at least one argument after the table")

	if value == nil then
		value = pos
		pos = tableLength(t :: any) + 1
	end

	local n = tableLength(t :: any)
	assert(pos >= 1 and pos <= n + 1, "bad argument #2 to 'insert' (position out of bounds)")

	-- shift only if not appending
	for i = n, pos, -1 do
		t[i + 1] = t[i]
	end

	t[pos] = value
end

-- returns the length of the array portion of the table
function TableTracker.len(t): number
	local ok, mt = isTracked(t)
	assert(ok and mt, "TableTracker.len expects a tracked table")

	return tableLength(mt.__raw)
end

-- removes and returns the element at position pos (or the last element if pos is nil)
function TableTracker.remove(t, pos: number?): any
	assert(isTracked(t), "TableTracker.remove expects a tracked table")

	local n = tableLength(t :: any)
	if pos == nil then
		pos = n
	end

	assert(type(pos) == "number" and pos >= 1 and pos <= n, "bad argument #2 to 'remove' (position out of bounds)")

	local old = t[pos]

	-- shift elements down
	for i = pos, n - 1 do
		t[i] = t[i + 1]
	end

	t[n] = nil -- remove last duplicate
	return old
end

return TableTracker
