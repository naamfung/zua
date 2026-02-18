print("Hello, World!")
print("1 + 2 = " .. (1 + 2))
print("Table test:")
local t = {}
t[1] = "one"
t[2] = "two"
t[3] = "three"
for i, v in ipairs(t) do
    print(i .. ": " .. v)
end
print("Script finished successfully!")