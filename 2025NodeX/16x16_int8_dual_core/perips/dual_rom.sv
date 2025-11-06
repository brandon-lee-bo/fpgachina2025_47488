//用于存储指令，接口按照内部总线，这里采用双端口
//PORT1用于instr存储器，PORT2用于scalar_operand存储器
//分块存储两个core的指令和scalar_operand(在执行的指令完全相同的情况下能不能不区分instr?)
//0000-0FFF core0 instr（0~1023）
//1000-1FFF core1 instr（1024~2047）
//2000-2FFF core0 scalar_operand（2048~3071）
//3000-3FFF core1 scalar_operand（3072~4095）
module dual_rom(
    input clk,
    input rstn,
    //PORT1
    input   wire            instr_req_i,    //instr读请求
    input   wire    [31:0]  instr_addr_i,   //instr读请求地址
    output  logic   [31:0]  rd_instr_o,     //instr读数据
    //PORT2
    input   wire            scalar_req_i,   //scalar读请求
    input   wire    [31:0]  scalar_addr_i,  //scalar读请求地址
    output  logic   [31:0]  rd_scalar_o     //scalar读数据     
);

    reg [31:0] dual_rom [0:4095];
    reg [31:0] instr_addr;
    reg [31:0] scalar_addr;

    //always_ff @(posedge clk or negedge rstn) begin
    //    if(~rstn) begin
    //        rd_instr_o  <= 32'h0000_0000;
    //        rd_scalar_o <= 32'h0000_0000;
    //    end else if(instr_req_i) begin
    //        automatic integer instr_idx  = instr_addr_i >> 2; // 每 4 字节一个单元 (32 位)
    //        automatic integer scalar_idx = (instr_addr_i + 32'h0000_2000) >> 2; // 每 4 字节一个单元 (32 位)
    //        rd_instr_o  <= dual_rom[(instr_addr_i >> 2)];
    //        rd_scalar_o <= dual_rom[(instr_addr_i + 32'h0000_2000) >> 2];
    //    end
    //end

    always_comb begin
        instr_addr = instr_addr_i >> 2;
        scalar_addr = (instr_addr_i + 32'h0000_2000) >> 2;
    end

    always_comb begin
        if(instr_req_i) begin
            rd_instr_o  <= dual_rom[instr_addr];
            rd_scalar_o <= dual_rom[scalar_addr];
        end
    end

endmodule