const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("lex.zig").Token;

pub const Tree = struct {
    node: *Node,

    /// not owned by the tree
    source: []const u8,

    arena: std.heap.ArenaAllocator.State,
    allocator: Allocator,

    pub fn deinit(self: *Tree) void {
        self.arena.promote(self.allocator).deinit();
    }

    pub fn chunk(self: *Tree) *Node.Chunk {
        return @alignCast(@fieldParentPtr("base", self.node));
    }

    pub fn dump(self: *Tree, writer: anytype) @TypeOf(writer).Error!void {
        try self.node.dump(writer, 0);
    }
};

pub const Node = struct {
    id: Id,

    pub const Id = enum {
        chunk,
        call,
        literal,
        identifier,
        assignment_statement,
        field_access,
        index_access,
        if_statement,
        if_clause,
        return_statement,
        while_statement,
        do_statement,
        repeat_statement,
        break_statement,
        for_statement_numeric,
        for_statement_generic,
        function_declaration,
        table_constructor,
        table_field,
        unary_expression,
        binary_expression,
        grouped_expression,

        pub fn Type(id: Id) type {
            return switch (id) {
                .chunk => Chunk,
                .call => Call,
                .literal => Literal,
                .identifier => Identifier,
                .assignment_statement => AssignmentStatement,
                .field_access => FieldAccess,
                .index_access => IndexAccess,
                .if_statement => IfStatement,
                .if_clause => IfClause,
                .return_statement => ReturnStatement,
                .while_statement => WhileStatement,
                .do_statement => DoStatement,
                .repeat_statement => RepeatStatement,
                .break_statement => BreakStatement,
                .for_statement_numeric => ForStatementNumeric,
                .for_statement_generic => ForStatementGeneric,
                .function_declaration => FunctionDeclaration,
                .table_constructor => TableConstructor,
                .table_field => TableField,
                .unary_expression => UnaryExpression,
                .binary_expression => BinaryExpression,
                .grouped_expression => GroupedExpression,
            };
        }
    };

    pub fn cast(base: *Node, comptime id: Id) ?*id.Type() {
        if (base.id == id) {
            return @alignCast(@fieldParentPtr("base", base));
        }
        return null;
    }

    pub const Chunk = struct {
        base: Node = .{ .id = .chunk },
        body: []*Node,
    };

    pub const Call = struct {
        base: Node = .{ .id = .call },
        expression: *Node,
        arguments: []*Node,
        open_args_token: ?Token,
        close_args_token: ?Token,
        is_statement: bool = false,
    };

    pub const Literal = struct {
        base: Node = .{ .id = .literal },
        /// Can be one of .keyword_nil, .keyword_true, .keyword_false, .number, .string, or .name
        /// (.name is a special case that is only used for table constructor field keys)
        token: Token,
    };

    pub const Identifier = struct {
        base: Node = .{ .id = .identifier },
        token: Token,
    };

    pub const AssignmentStatement = struct {
        base: Node = .{ .id = .assignment_statement },
        variables: []*Node,
        values: []*Node,
        is_local: bool,
    };

    pub const FieldAccess = struct {
        base: Node = .{ .id = .field_access },
        prefix: *Node,
        field: Token,
        separator: Token,
    };

    pub const IndexAccess = struct {
        base: Node = .{ .id = .index_access },
        prefix: *Node,
        index: *Node,
        open_token: Token,
        close_token: Token,
    };

    pub const IfStatement = struct {
        base: Node = .{ .id = .if_statement },
        clauses: []*Node,
    };

    /// if, elseif, or else
    pub const IfClause = struct {
        base: Node = .{ .id = .if_clause },
        if_token: Token,
        condition: ?*Node,
        body: []*Node,
    };

    pub const ReturnStatement = struct {
        base: Node = .{ .id = .return_statement },
        values: []*Node,
    };

    pub const WhileStatement = struct {
        base: Node = .{ .id = .while_statement },
        condition: *Node,
        body: []*Node,
    };

    pub const DoStatement = struct {
        base: Node = .{ .id = .do_statement },
        body: []*Node,
    };

    pub const RepeatStatement = struct {
        base: Node = .{ .id = .repeat_statement },
        body: []*Node,
        condition: *Node,
    };

    pub const BreakStatement = struct {
        base: Node = .{ .id = .break_statement },
        token: Token,
    };

    pub const ForStatementNumeric = struct {
        base: Node = .{ .id = .for_statement_numeric },
        name: Token,
        start: *Node,
        end: *Node,
        increment: ?*Node,
        body: []*Node,
    };

    pub const ForStatementGeneric = struct {
        base: Node = .{ .id = .for_statement_generic },
        names: []Token,
        expressions: []*Node,
        body: []*Node,
    };

    pub const FunctionDeclaration = struct {
        base: Node = .{ .id = .function_declaration },
        name: ?*Node, // null for anonymous functions
        parameters: []Token,
        body: []*Node,
        is_local: bool,
    };

    pub const TableConstructor = struct {
        base: Node = .{ .id = .table_constructor },
        fields: []*Node,
        open_token: Token,
        close_token: Token,
    };

    pub const TableField = struct {
        base: Node = .{ .id = .table_field },
        key: ?*Node,
        value: *Node,
    };

    pub const UnaryExpression = struct {
        base: Node = .{ .id = .unary_expression },
        operator: Token,
        argument: *Node,
    };

    pub const BinaryExpression = struct {
        base: Node = .{ .id = .binary_expression },
        operator: Token,
        left: *Node,
        right: *Node,
    };

    pub const GroupedExpression = struct {
        base: Node = .{ .id = .grouped_expression },
        open_token: Token,
        expression: *Node,
        close_token: Token,
    };

    /// Gets the last token of an expression
    /// Needed for detecting ambiguous function calls
    pub fn getLastToken(node: *const Node) Token {
        switch (node.id) {
            .identifier => {
                const casted: *const Identifier = @alignCast(@fieldParentPtr("base", node));
                return casted.token;
            },
            .grouped_expression => {
                const casted: *const GroupedExpression = @alignCast(@fieldParentPtr("base", node));
                return casted.close_token;
            },
            .field_access => {
                const casted: *const FieldAccess = @alignCast(@fieldParentPtr("base", node));
                return casted.field;
            },
            .index_access => {
                const casted: *const IndexAccess = @alignCast(@fieldParentPtr("base", node));
                return casted.close_token;
            },
            .call => {
                const casted: *const Call = @alignCast(@fieldParentPtr("base", node));
                if (casted.close_args_token) |close_token| {
                    return close_token;
                } else {
                    return casted.arguments[casted.arguments.len - 1].getLastToken();
                }
            },
            .literal => {
                const casted: *const Literal = @alignCast(@fieldParentPtr("base", node));
                return casted.token;
            },
            .table_constructor => {
                const casted: *const TableConstructor = @alignCast(@fieldParentPtr("base", node));
                return casted.close_token;
            },
            else => {
                std.debug.print("{}\n", .{node});
                @panic("TODO");
            },
        }
    }

    pub fn dump(
        node: *const Node,
        writer: anytype,
        indent: usize,
    ) @TypeOf(writer).Error!void {
        try writer.writeByteNTimes(' ', indent);
        try writer.writeAll(@tagName(node.id));
        switch (node.id) {
            .chunk => {
                try writer.writeAll("\n");
                const chunk: *const Chunk = @alignCast(@fieldParentPtr("base", node));
                for (chunk.body) |body_node| {
                    try body_node.dump(writer, indent + 1);
                }
            },
            .call => {
                try writer.writeAll("\n");
                const call: *const Call = @alignCast(@fieldParentPtr("base", node));
                try call.expression.dump(writer, indent + 1);
                try writer.writeByteNTimes(' ', indent + 1);
                try writer.writeAll("(");
                if (call.arguments.len > 0) {
                    try writer.writeAll("\n");
                    for (call.arguments) |arg_node| {
                        try arg_node.dump(writer, indent + 2);
                    }
                    try writer.writeByteNTimes(' ', indent + 1);
                }
                try writer.writeAll(")\n");
            },
            .identifier => {
                try writer.writeAll("\n");
            },
            .literal => {
                const literal: *const Literal = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll(" ");
                try writer.writeAll(literal.token.nameForDisplay());
                try writer.writeAll("\n");
            },
            .assignment_statement => {
                const assignment: *const AssignmentStatement = @alignCast(@fieldParentPtr("base", node));
                if (assignment.is_local) {
                    try writer.writeAll(" local");
                }
                try writer.writeAll("\n");
                for (assignment.variables) |var_node| {
                    try var_node.dump(writer, indent + 1);
                }
                if (assignment.values.len > 0) {
                    try writer.writeByteNTimes(' ', indent);
                    try writer.writeAll("=\n");
                    for (assignment.values) |value_node| {
                        try value_node.dump(writer, indent + 1);
                    }
                }
            },
            .field_access => {
                const field_access: *const FieldAccess = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll(" ");
                try writer.writeAll(field_access.separator.nameForDisplay());
                try writer.writeAll(field_access.field.nameForDisplay());
                try writer.writeAll("\n");
                try field_access.prefix.dump(writer, indent + 1);
            },
            .index_access => {
                const index_access: *const IndexAccess = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                try index_access.prefix.dump(writer, indent + 1);
                try index_access.index.dump(writer, indent + 1);
            },
            .if_statement => {
                const if_statement: *const IfStatement = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                for (if_statement.clauses) |clause| {
                    try clause.dump(writer, indent + 1);
                }
            },
            .if_clause => {
                const if_clause: *const IfClause = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll(" ");
                try writer.writeAll(if_clause.if_token.nameForDisplay());
                try writer.writeAll("\n");
                if (if_clause.condition) |condition| {
                    try condition.dump(writer, indent + 1);
                    try writer.writeByteNTimes(' ', indent);
                    try writer.writeAll("then\n");
                }
                for (if_clause.body) |body_node| {
                    try body_node.dump(writer, indent + 1);
                }
            },
            .return_statement => {
                const return_statement: *const ReturnStatement = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                for (return_statement.values) |value_node| {
                    try value_node.dump(writer, indent + 1);
                }
            },
            .while_statement => {
                const while_statement: *const WhileStatement = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                try while_statement.condition.dump(writer, indent + 1);
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("do\n");
                for (while_statement.body) |body_node| {
                    try body_node.dump(writer, indent + 1);
                }
            },
            .do_statement => {
                const do_statement: *const DoStatement = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                for (do_statement.body) |body_node| {
                    try body_node.dump(writer, indent + 1);
                }
            },
            .repeat_statement => {
                const repeat_statement: *const RepeatStatement = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                for (repeat_statement.body) |body_node| {
                    try body_node.dump(writer, indent + 1);
                }
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("until\n");
                try repeat_statement.condition.dump(writer, indent + 1);
            },
            .break_statement => {
                try writer.writeAll("\n");
            },
            .for_statement_numeric => {
                const for_statement: *const ForStatementNumeric = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                try for_statement.start.dump(writer, indent + 1);
                try for_statement.end.dump(writer, indent + 1);
                if (for_statement.increment) |increment| {
                    try increment.dump(writer, indent + 1);
                }
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("do\n");
                for (for_statement.body) |body_node| {
                    try body_node.dump(writer, indent + 1);
                }
            },
            .for_statement_generic => {
                const for_statement: *const ForStatementGeneric = @alignCast(@fieldParentPtr("base", node));
                for (for_statement.names) |name_token| {
                    try writer.writeAll(" ");
                    try writer.writeAll(name_token.nameForDisplay());
                }
                try writer.writeAll("\n");
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("in\n");
                for (for_statement.expressions) |exp_node| {
                    try exp_node.dump(writer, indent + 1);
                }
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("do\n");
                for (for_statement.body) |body_node| {
                    try body_node.dump(writer, indent + 1);
                }
            },
            .function_declaration => {
                const func: *const FunctionDeclaration = @alignCast(@fieldParentPtr("base", node));
                if (func.is_local) {
                    try writer.writeAll(" local");
                }
                try writer.writeAll("\n");
                if (func.name) |name| {
                    try name.dump(writer, indent + 1);
                }
                try writer.writeByteNTimes(' ', indent + 1);
                try writer.writeAll("(");
                for (func.parameters, 0..) |param, i| {
                    if (i != 0) try writer.writeAll(" ");
                    try writer.writeAll(param.nameForDisplay());
                }
                try writer.writeAll(")\n");
                for (func.body) |body_node| {
                    try body_node.dump(writer, indent + 2);
                }
            },
            .table_constructor => {
                const constructor: *const TableConstructor = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                for (constructor.fields) |field| {
                    try field.dump(writer, indent + 1);
                }
            },
            .table_field => {
                const field: *const TableField = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                if (field.key) |key| {
                    try key.dump(writer, indent + 1);
                    try writer.writeByteNTimes(' ', indent);
                    try writer.writeAll("=\n");
                }
                try field.value.dump(writer, indent + 1);
            },
            .unary_expression => {
                const unary: *const UnaryExpression = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll(" ");
                try writer.writeAll(unary.operator.nameForDisplay());
                try writer.writeAll("\n");
                try unary.argument.dump(writer, indent + 1);
            },
            .binary_expression => {
                const binary: *const BinaryExpression = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll(" ");
                try writer.writeAll(binary.operator.nameForDisplay());
                try writer.writeAll("\n");
                try binary.left.dump(writer, indent + 1);
                try binary.right.dump(writer, indent + 1);
            },
            .grouped_expression => {
                const grouped: *const GroupedExpression = @alignCast(@fieldParentPtr("base", node));
                try writer.writeAll("\n");
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll(grouped.open_token.nameForDisplay());
                try writer.writeAll("\n");
                try grouped.expression.dump(writer, indent + 1);
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll(grouped.close_token.nameForDisplay());
                try writer.writeAll("\n");
            },
        }
    }
};
