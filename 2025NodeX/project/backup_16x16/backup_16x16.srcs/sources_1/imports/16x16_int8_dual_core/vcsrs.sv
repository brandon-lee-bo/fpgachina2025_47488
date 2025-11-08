// vector_csrs 模块
// 功能：管理 RISC-V 向量处理器的向量配置状态寄存器（Vector CSRs），支持 vsetvl 指令写入，
//       为 vlsu 和 vex 提供 vl、vsew 和 vlmul 参数，优化用于 GEMV 操作
// vlmul具体含义查看gork中代码问题，设置大于1时，表示一条指令操控多个向量寄存器，减少读指令的次数

module vcsrs (
    // 输出信号：供 vlsu 和 vex 使用
    output logic [7:0] vl,                  // 向量长度，8 位，
    output logic [1:0] vsew,                // 向量元素宽度，3 位（000: 8位, 001: 16位, 010: 32位）
    output logic [1:0] vlmul,               // 向量长度乘数，3 位（000: 1, 001: 2, 010: 4, 011: 8）

    // 输入信号
    input wire clk,                         // 时钟信号
    input wire rstn,                        // 复位信号，低有效（改为 rstn 与原代码一致）
    input wire [31:0] avl_in,               // 应用向量长度（AVL），来自 vid 的操作数
    input wire [7:0] vtype_in,              // 向量类型，8 位，包含 vsew 和 vlmul
    input wire write,                       // 写使能信号，来自 vid 的 vsetvl 控制信号
    input wire preserve_vl                 // 保持当前 vl 标志，1 时不更新 vl
);
// write为更新 vtype 和 vl；preserve_vl为保持当前 vl 标志


// 内部宏定义
`define VLENB           32'd16          // 定义向量寄存器长度为 16 字节（32*4bank=128 位）
`define VSEW_WIDTH      1:0             // vsew 的位宽，3 位
`define VLMUL_WIDTH     1:0             // vlmul 的位宽，3 位
`define VL_WIDTH        7:0             // vl 的位宽，7 位

`define VTYPE_VSEW      3:2             // vtype 中 vsew 的位置
`define VTYPE_VLMUL     1:0             // vtype 中 vlmul 的位置（简化，未使用符号位）

// 内部寄存器：存储 CSR 值
logic [31:0] csrs [2:0];                 // CSR 数组：0: vtype, 1: vl, 2: vlenb（只读）

// 内部信号
logic [`VL_WIDTH] vl_next;               // 下一周期的 vl 值
logic [`VL_WIDTH] max_vl;                // 最大 vl 值
logic [4:0] per_reg;                     // 每个寄存器容纳的元素数

// CSR reg更新逻辑
always_ff @(posedge clk or negedge rstn) begin
    if (~rstn) begin
        // 复位时：初始化 CSR
        csrs[0] <= '0;                   // vtype 清零
        csrs[1] <= '0;                   // vl 清零
        csrs[2] <= `VLENB;               // vlenb 设为 16 字节（128 位），只读
    end else if (write) begin
        // 写使能时：更新 vtype 和 vl
        csrs[0] <= {'0, vtype_in};       // 更新 vtype，填充高位为 0
        if (~preserve_vl) begin
            // 若不保持 vl，则更新为 vl_next，其值可能为 AVL 或 计算的max_vl
            csrs[1] <= {'0, vl_next};
        end
    end
    else begin
        csrs[0] <= csrs[0];
        csrs[1] <= csrs[1];
    end
end

// 向量参数计算逻辑
always_comb begin
    // 计算每个寄存器容纳的元素数：vlenb / sew
    // sew = 2^(vsew + 3) 字节，vlenb = 16 字节
    case (vtype_in[`VTYPE_VSEW])
        3'b000: per_reg = 16;            // sew = 8 位 (1 字节)，16 / 1 = 16
        3'b001: per_reg = 8;             // sew = 16 位 (2 字节)，16 / 2 = 8
        3'b010: per_reg = 4;             // sew = 32 位 (4 字节)，16 / 4 = 4
        default: per_reg = 16;           // 默认 8 位（int8）
    endcase

    // 计算最大 vl：per_reg * lmul  最多能处理的元素数
    // lmul = 2^vlmul（忽略负值的分数，简化处理）
    max_vl = per_reg << vtype_in[`VTYPE_VLMUL];

    // 计算下一周期的 vl
    if ( avl_in > max_vl ) begin
        // 若设置最大 vl 或 AVL 超出最大值，则使用 max_vl
        vl_next = max_vl;
    end else begin
        // 否则使用 AVL 的低 7 位
        vl_next = avl_in[`VL_WIDTH];
    end
end

// 输出赋值
assign vl = csrs[1][`VL_WIDTH];          // 输出当前 vl
assign vsew = csrs[0][`VTYPE_VSEW];      // 输出当前 vsew
assign vlmul = csrs[0][`VTYPE_VLMUL];    // 输出当前 vlmul（低 2 位，忽略符号位）

endmodule