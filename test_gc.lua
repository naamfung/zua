-- Test garbage collector and object lifecycle management

-- Test 1: Basic garbage collection
print("Test 1: Basic garbage collection")
local count = 0
for i = 1, 10000 do
    local t = {}
    count = count + 1
end
print("Created " .. count .. " tables")

-- Test 2: Circular references
print("\nTest 2: Circular references")
local a = {}
local b = {}
a.b = b
b.a = a
print("Created circular references")
a = nil
b = nil
print("Cleared references")

-- Test 3: String interning
print("\nTest 3: String interning")
local s1 = "hello world"
local s2 = "hello world"
print("Created two identical strings")
print("s1 and s2 are the same object: " .. tostring(s1 == s2))

-- Test 4: Closures and upvalues
print("\nTest 4: Closures and upvalues")
function create_closure()
    local x = 10
    return function()
        x = x + 1
        return x
    end
end

local f1 = create_closure()
local f2 = create_closure()
print("Created two closures with upvalues")
print("f1(): " .. f1())
print("f1(): " .. f1())
print("f2(): " .. f2())
print("f2(): " .. f2())

-- Test 5: Garbage collection under load
print("\nTest 5: Garbage collection under load")
local function create_large_table(size)
    local t = {}
    for i = 1, size do
        t[i] = "string " .. i
    end
    return t
end

local tables = {}
for i = 1, 100 do
    tables[i] = create_large_table(1000)
end
print("Created 100 large tables")
tables = nil
print("Cleared table references")

print("\nAll tests completed!")
