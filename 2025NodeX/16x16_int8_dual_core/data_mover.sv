module data_mover#(
    parameter DATA_WIDTH = 32
) (
    input clk,
    input rst_n,

    input                               mover_activate,//由ctrl发出，指示开始data_mover
    input           [DATA_WIDTH - 1:0]  move_data_i,
    output logic                        data_mover_en_o,//给core里的dense_buffer
    output logic    [DATA_WIDTH - 1:0]  move_data_o
);
    








endmodule