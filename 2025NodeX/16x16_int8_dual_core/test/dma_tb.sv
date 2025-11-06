`timescale 1ns/1ps

module dma_tb;

    logic clk;
    logic rstn;
    logic nib_hold_req_i;
    logic [31:0] addr_data_i;
    logic [7:0] max_data_count;
    logic instr_valid_i;
    logic store_mem_en;
    logic [31:0] store_data;
    logic buf_load_en;
    logic data_req_o;
    logic sparse_store_done;
    logic data_out_flag;
    logic [31:0] load_data_o;
    logic write_en;
    logic [31:0] write_data;
    logic write_req_o;
    logic [31:0] write_data_o;
    logic [31:0] external_addr;

    // 实例化待测模块
    dma dut (
        .clk(clk),
        .rstn(rstn),
        .nib_hold_req_i(nib_hold_req_i),
        .addr_data_i(addr_data_i),
        .max_data_count(max_data_count),
        .instr_valid_i(instr_valid_i),
        .store_mem_en(store_mem_en),
        .store_data(store_data),
        .buf_load_en(buf_load_en),
        .data_req_o(data_req_o),
        .sparse_store_done(sparse_store_done),
        .data_out_flag(data_out_flag),
        .load_data_o(load_data_o),
        .write_en(write_en),
        .write_data(write_data),
        .write_req_o(write_req_o),
        .write_data_o(write_data_o),
        .external_addr(external_addr)
    );

    // 时钟生成
    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        rstn = 0;
        nib_hold_req_i = 0;
        addr_data_i = 32'h1000_0000;
        max_data_count = 8'd4;
        instr_valid_i = 0;
        store_mem_en = 0;
        store_data = 32'h0;
        buf_load_en = 0;
        write_en = 0;
        write_data = 32'h0;
        #20;
        rstn = 1;
        #10;

        // ----------- 测试读功能 -----------
        instr_valid_i = 1;
        #10;
        instr_valid_i = 0;

        // 模拟外部每拍返回数据
        repeat (max_data_count) begin
            @(posedge clk);
            store_data = 32'hA000_0000 + load_data_o;
            $display("[READ] cycle=%0t, data_req_o=%b, external_addr=%h, load_data_o=%h, data_out_flag=%b, sparse_store_done=%b",
                $time, data_req_o, external_addr, load_data_o, data_out_flag, sparse_store_done);
        end

        @(negedge clk);
        $display("[READ DONE] sparse_store_done=%b, external_addr=%h", sparse_store_done, external_addr);
        #50;

        // ----------- 测试写功能 -----------
        write_en = 1;
        write_data = 32'hBEEF_0001;
        @(posedge clk);
        write_en = 0;

        repeat (2) begin
            @(posedge clk);
            write_data = write_data + 1;
            addr_data_i = addr_data_i + 4;
            $display("[WRITE] cycle=%0t, write_req_o=%b, external_addr=%h, write_data_o=%h",
                $time, write_req_o, external_addr, write_data_o);
        end

        @(negedge clk);
        $display("[WRITE DONE] write_req_o=%b, external_addr=%h, write_data_o=%h", write_req_o, external_addr, write_data_o);

        #20;
        $finish;
    end

endmodule