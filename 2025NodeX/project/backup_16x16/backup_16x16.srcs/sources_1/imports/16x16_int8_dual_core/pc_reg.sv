// pc_reg 模块
// 功能：生成 RISC-V 向量处理器的程序计数器地址，通过 AXI 总线与外部存储器交互取指
module pc_reg #(
    parameter PC_INIT = 32'h0000_0000  // PC 初始地址
)(
    output reg [31:0] pc_o,                 // 连接 axi_pc_addr_o
    output reg        pc_req_o,             

    input wire clk,                        
    input wire rstn,                       
    input wire hold_flag_i            // 暂停标志，来自 ctrl 模块（最低一位）
);

// 内部宏定义
`define INST_ADDR_WIDTH 31:0            // 定义指令地址总线宽度为 32 位
`define INST_WIDTH      32'h4           // 定义指令宽度为 4 字节（32 位指令）
`define HOLD_PC         1'b1            // 定义暂停 PC 状态
`define DISABLE         1'b0            // 定义不向外部请求数据
`define ENABLE          1'b1            // 定义向外部请求指令

// 内部寄存器
reg [`INST_ADDR_WIDTH] pc_reg;          // 内部 PC 寄存器，存储当前指令地址

// PC 更新逻辑
always @(posedge clk or negedge rstn) begin
    if (rstn == 1'b0) begin
        // 复位将 PC 初始化为默认起始地址
        pc_reg <= PC_INIT;
    end else begin
        // 判断是否更新 PC
        if (hold_flag_i == `HOLD_PC) begin
            // HOLD_PC 时保持 PC 不变
            pc_reg <= pc_reg;
        end else begin
            // PC 递增 4，指向下一条指令
            pc_reg <= pc_reg + `INST_WIDTH;
        end
    end
end

// 输出逻辑：将内部 PC 寄存器值赋给 pc_o
always @(*) begin
    pc_o = pc_reg;                       // 输出：当前 PC 值，供 AXI 总线取指使用
    if(hold_flag_i != `HOLD_PC && rstn) begin
        pc_req_o = `ENABLE;
    end else begin
        pc_req_o = `DISABLE;
    end
end

endmodule