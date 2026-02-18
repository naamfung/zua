-- Simple test for garbage collector

print("Testing garbage collector...")

-- Test 1: Basic allocation
print("\nTest 1: Basic allocation")
local t1 = {}
print("Created table t1")
local t2 = {}
print("Created table t2")

-- Test 2: Assignment and collection
t1 = nil
print("Assigned nil to t1")
t2 = nil
print("Assigned nil to t2")

-- Test 3: String creation
print("\nTest 3: String creation")
local s1 = "test string"
print("Created string s1")
local s2 = "test string"
print("Created string s2")

print("\nAll tests completed!")
