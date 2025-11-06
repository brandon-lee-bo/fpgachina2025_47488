//稀疏矩阵数据寄存器
//用于存储要用于spmm计算的数据
//采用csr格式，分为data，indices，index
    module sparse_buf (
        input   wire            clk,
        input   wire            rstn,
        input   wire            load_en,//从buffer读出数据给vex
        input   wire            store_en,//从dma存储数据到buffer
        input   wire    [31:0]  store_data,//从dma取到的数据

        output  logic   [31:0] sparse_data,
        output  logic           data_ready
    );

    logic [1119:0] sparse_buf;
    logic [7:0] store_data_count; //数据计数器，用于记录已经存储了多少个32位数据
    logic [7:0] load_data_count;
    localparam MAX_DATA_COUNT = 35; //最大数据计数值

    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            sparse_data <= '0;
            load_data_count <= 0;
            data_ready <= '0;
        end else begin
            if(store_en) begin
                data_ready <= 1'b0;
                load_data_count <= '0;
            end else if(load_en && load_data_count < MAX_DATA_COUNT && !data_ready) begin
                sparse_data <= sparse_buf[(load_data_count)*32 +: 32]; //存储数据到稀疏矩阵寄存器
                load_data_count <= load_data_count + 1; //计数器加1
                data_ready <= '0;
            end else if(load_data_count == MAX_DATA_COUNT) begin
                data_ready <= 1'b1;
            end else begin
                data_ready <= data_ready;
            end
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            sparse_buf <= '0;
            store_data_count <= 0;
        end else begin
            if(store_en && store_data_count < MAX_DATA_COUNT) begin
                sparse_buf[(store_data_count)*32 +: 32] <= store_data; //存储数据到稀疏矩阵寄存器
                store_data_count <= store_data_count + 1; //计数器加1
            end else if(store_data_count == MAX_DATA_COUNT) begin
                store_data_count <= 0; //计数器归零，准备下一次存储
            end
        end
    end

    endmodule 