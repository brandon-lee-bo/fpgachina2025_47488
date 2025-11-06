//data mover的控制模块，
module data_mover_ctrl #(
    parameter CORE_NUM = 2
) (
    input clk,
    input rst_n,
    input [CORE_NUM - 1:0] core_move_finish_i,
    output [CORE_NUM - 1:0] core_move_en_o,
);
    logic 
    always_comb begin : 
        for (int i = 0; i < CORE_NUM; i++) begin
            





endmodule