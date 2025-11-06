module dense_buf #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 32,
    parameter DEPTH = 60
    )(
    input  wire           clk,
    input  wire           rstn,

    //写通道
    input  wire           write_en_i,
    input  wire   [5:0]  write_addr_i,
    input  wire   [127:0] write_data_i,

    //读通道
    input  wire           read_en_i,
    input  wire   [5:0]  read_addr_i,
    output logic  [127:0] read_data_o
);
    //内部存储器
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // 写操作（组合逻辑）
    always_comb begin
        // 默认值
        if(~rstn) begin
            for(int i = 0; i < DEPTH; i++) begin
                mem[i] = '0;
            end
        end else if (write_en_i) begin
            // 组合写：当使能且写使能时立即写入
            mem[write_addr_i] = write_data_i;
        end
    end

    // 读操作（组合逻辑）
    always_comb begin
        read_data_o  = '0;
        if (read_en_i && write_en_i) begin
            if(write_addr_i == read_addr_i) begin
                read_data_o = write_data_i;
            end
        end else if (read_en_i) begin
            // 组合读：立即从存储中取数据
            read_data_o  = mem[read_addr_i];
        end
    end

endmodule