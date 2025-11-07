import rvv_pkg::*;


// 指令执行：解码->load（需暂停pc和id）- store（需暂停pc和id）->execute（需暂停pc和id）
// todo: 功能全部实现后，考虑拆分为1 bit的暂停请求，对功耗面积进行优化
// 控制模块
// 功能：控制 RISC-V 向量处理器的流水线暂停，支持跨模块暂停请求，每个模块请求合并为 4 位信号
module ctrl (
    // 输出控制信号
    output reg [3:0] hold_ctrl_o,            // 输出：4位暂停控制信号，每位独立控制一个模块

    input wire rstn,                         // 输入：复位信号，高有效

    // 来自 vlsu 的合并暂停请求
    input wire [3:0] hold_vid_req_i,        // 输入：vlsu 的 4 位暂停请求信号

    // 来自 vex 的合并暂停请求
    input wire [3:0] hold_vex_req_i,         // 输入：vex 的 4 位暂停请求信号

    // 来自外部总线的暂停请求
    input wire hold_axi_req_i                 // 输入：总线请求暂停 pc_reg，高有效
    
);

// 定义暂停控制信号的位字段
`define HOLD_VLSU_BIT 3                     // 第 3 位：控制 vlsu 暂停
`define HOLD_VEX_BIT  2                     // 第 2 位：控制 vex 暂停
`define HOLD_VID_BIT  1                     // 第 1 位：控制 vid 暂停
`define HOLD_PC_BIT   0                     // 第 0 位：控制 pc_reg 暂停

`define HOLD_ENABLE   1'b1                  // 定义暂停使能值为高有效
`define HOLD_DISABLE  1'b0                  // 定义暂停禁用值为低电平

always @ (*) begin
    if (rstn == 1'b0) begin
        // 复位状态：清除所有暂停信号，所有模块正常运行
        hold_ctrl_o = 4'b0000;
    end else begin

        // pc_reg 暂停：由总线、vid 或 vex 请求
        hold_ctrl_o[`HOLD_PC_BIT] = (hold_axi_req_i == 1'b1 || 
                                     hold_vid_req_i[`HOLD_PC_BIT] == 1'b1 || 
                                     hold_vex_req_i[`HOLD_PC_BIT] == 1'b1) 
                                    ? `HOLD_ENABLE : 1'b0;

        // vid 暂停：由 vid、vlsu 或 vex 请求
        hold_ctrl_o[`HOLD_VID_BIT] = (hold_axi_req_i == 1'b1 ||
                                      hold_vid_req_i[`HOLD_VID_BIT] == 1'b1 || 
                                      hold_vex_req_i[`HOLD_VID_BIT] == 1'b1) 
                                     ? `HOLD_ENABLE : 1'b0;

        // vex 暂停：由 vex 或 vlsu 请求
        hold_ctrl_o[`HOLD_VEX_BIT] = (hold_vex_req_i[`HOLD_VEX_BIT] == 1'b1 || 
                                      hold_vid_req_i[`HOLD_VEX_BIT] == 1'b1) 
                                     ? `HOLD_ENABLE : 1'b0;

        // vlsu 暂停：仅由 vlsu 请求
        hold_ctrl_o[`HOLD_VLSU_BIT] = (hold_vid_req_i[`HOLD_VLSU_BIT] == 1'b1) 
                                      ? `HOLD_ENABLE : 1'b0;
    end
end

endmodule


