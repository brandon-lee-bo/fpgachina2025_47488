//用于存储计算需要的data
module ram(
    input clk,
    input rstn,
    input   wire            ram_req_i,      //ram读请求
    input   wire    [31:0]  ram_addr_i,     //ram读请求地址
    output  logic   [31:0]  rd_ram_o,        //ram读数据
    input   wire            ram_we_i,       //ram写请求
    input   wire    [31:0]  ram_wdata_i     //ram写数据
);

    reg [31:0] ram [0:4095];
    logic [31:0] idx;
    always_comb begin
        idx = ram_addr_i >> 2;
    end

    //always_ff @(posedge clk ) begin
    //    if(ram_req_i) begin
    //        rd_ram_o <= ram[idx];//从0开始
    //    end else begin
    //        rd_ram_o <= rd_ram_o;
    //    end
    //end

    always_comb begin
        if(ram_req_i) begin
            rd_ram_o = ram[idx];//从0开始
        end else begin
            rd_ram_o = rd_ram_o;
        end   
    end

    always_ff @(posedge clk) begin
        if(ram_we_i) begin
            ram[idx] <= ram_wdata_i;
        end
    end


endmodule