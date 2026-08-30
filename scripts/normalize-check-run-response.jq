if type == "object" then .
elif type == "array" and length == 1 and (.[0] | type) == "object" then .[0]
else error("check-run response must be one object or a one-object array")
end |
if ((.total_count | type) == "number" and (.total_count | floor) == .total_count and
    .total_count >= 0 and .total_count <= 100 and
    (.check_runs | type) == "array" and (.check_runs | length) == .total_count and
    all(.check_runs[]; .name == "Check linked issues"))
then .
else error("check-run response is malformed or incomplete")
end
