//if_id

`include "rvv_pkg.sv"
// 将指令向译码模块传递
// if_id：取指到译码之间的模块，用于将指令存储器输出的指令打一拍后送到译码模块。
module if_id(

    input wire clk,
    input wire rstn,

    input wire [1:0] [`InstBus] inst_i,            // 指令内容   32位
    input wire [`InstAddrBus] inst_addr_i,   // 指令地址   32位
    input wire hold_flag_i,            // 暂停标志同pc，来自 ctrl 模块（最低一位）

    output wire [1:0] [`InstBus] inst_o,           // 指令内容  32位
    output wire [`InstAddrBus] inst_addr_o   // 指令地址  32位

    );

    `define ZeroWord    32'h0
    `define INST_NOP    32'h00000001
    
    wire [`InstBus] instv;   //32位
    wire [`InstBus] insts;   //32位    
    wire hold_en = hold_flag_i;

    //例化 gen_pipe_dff 模块  如果没有复位或者暂停流水线，则指令内容inst_i被打一拍。
    gen_pipe_dff #(32) inst_ff0(clk, rstn, hold_en, inst_i[0], instv);     //向量指令
    assign inst_o[0] = instv;
    gen_pipe_dff #(32) inst_ff1(clk, rstn, hold_en, inst_i[1], insts);     //标量操作数
    assign inst_o[1] = insts;


    wire [`InstAddrBus] inst_addr;  //32位

    //例化 gen_pipe_dff 模块  如果没有复位或者暂停流水线，则指令地址inst_addr_i被打一拍。
    gen_pipe_dff #(32) inst_addr_ff(clk, rstn, hold_en, inst_addr_i, inst_addr);
    assign inst_addr_o = inst_addr;


endmodule


// 带默认值和控制信号的流水线触发器
module gen_pipe_dff #(
    parameter DW = 32)(

    input wire clk,
    input wire rstn,
    input wire hold_en,

    input wire [DW-1:0] din,
    output wire [DW-1:0] qout

    );

    reg[DW-1:0] din_r;
    reg[DW-1:0] qout_r;

    always @ (posedge clk or negedge rstn) begin
        if (rstn == 1'b0) begin
            din_r <= '0;
        end else if (hold_en == 1'b1) begin
            din_r <= din_r;
        end else begin
            din_r <= din;
        end
    end

    assign qout = din_r;

endmodule