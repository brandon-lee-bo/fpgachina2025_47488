`timescale 1ns / 1ps
//现在这个testbench是加入了dma之后连续计算两个spmm
import rvv_pkg::*;

module tb_riscv_core ();

    // 输入信号
    reg clk;
    reg rstn;
    reg [31:0] axi_ex_data_i;         // 从内存读取的数据 (32 位)
    reg [1:0][31:0] axi_pc_data_i;    // 取到的指令内容 (32 位)
    reg axi_hold_req_i;
    // 输出信号
    wire [31:0] axi_ex_addr_o;        // 内存访问地址 (32 位)
    wire [31:0] axi_ex_data_o;        // 写入内存的数据 (32 位)
    wire axi_ex_req_o;
    wire axi_ex_we_o;
    wire [31:0] axi_pc_addr_o;        // 取指地址 (32 位)
    reg data_rvalid;             // 数据有效标志
    reg data_gnt;               // 数据返回有效标志

    // 顶层模块实例化

    riscv_core u_riscv_core(
        .clk            (clk            ),
        .rstn           (rstn           ),
        .core_bus_spare (core_bus_spare ),
        .core_activate  (core_activate  ),
        .nib_ex_addr_o  (axi_ex_addr_o  ),
        .nib_ex_data_o  (axi_ex_data_o  ),
        .nib_ex_we_o    (axi_ex_we_o    ),
        .nib_ex_data_i  (axi_ex_data_i  ),
        .nib_ex_req_o   (axi_ex_req_o   ),
        .nib_pc_addr_o  (axi_pc_addr_o  ),
        .nib_pc_data_i  (axi_pc_data_i  ),
        .nib_pc_req_o   (nib_pc_req_o   ),
        .nib_hold_req_i (axi_hold_req_i )
    );

    // 外部存储定义 (32 位宽度，4096 个字)
    reg [31:0] external_mem [0:4095];
    reg [31:0] ram [0:4095];
    initial begin
        // 初始化存储器
        for (integer i = 0; i < 4096; i = i + 1) begin
            external_mem[i] = 32'h0; // 清零所有单元
            ram[i] = 32'h0;
        end
        $readmemb("instr_core0_init.txt", external_mem);
        $readmemh("scalar_core0_init.txt", external_mem, 2048);
        $readmemb("instr_core1_init.txt", external_mem, 1024);
        $readmemh("scalar_core1_init.txt", external_mem, 3072);
        $readmemh("external_mem_init.txt", ram);
    end

    // 时钟生成
    always begin
        #10 clk = ~clk; // 20ns 周期
    end

    // AXI 总线模拟
    always_comb begin : blockName
            if(nib_pc_req_o) begin
                axi_pc_data_i[0]  <= external_mem[axi_pc_addr_o >> 2];
                axi_pc_data_i[1]  <= external_mem[(axi_pc_addr_o + 32'h0000_2000) >> 2];
            end


            // 数据读取
            if (axi_ex_req_o && !axi_ex_we_o) begin

                data_rvalid <= 1'b1; // 模拟数据有效
                axi_ex_data_i <= ram[axi_ex_addr_o >> 2];
    
            end
            else begin
                data_rvalid <= 1'b0; // 模拟数据无效
            end

            // 数据写入
            if (axi_ex_we_o) begin
                data_gnt <= 1'b1; // 模拟数据返回有效

                ram[axi_ex_addr_o >> 2] <= axi_ex_data_o;
                $display("Time=%0t, Write Addr=%h, Data=%h", $time, axi_ex_addr_o, axi_ex_data_o);
            end
            else begin
                data_gnt <= 1'b0; // 模拟数据返回无效
            end
    end



    // 测试流程
    initial begin
        // 初始化信号
        clk = 1'b0;
        rstn = 1'b0;;
        axi_hold_req_i = '0;

        // 复位
        #10 rstn = 1'b1;
        $display("Reset complete at %0t", $time);

        // 等待指令执行
        #100; $display("vsetvli complete at %0t", $time);
        #200; $display("Loaded vs1 to v0 at %0t", $time);
        #100; $display("Loaded vs2 to v1 at %0t", $time);
        #100; $display("Performed gemv v2, v0, v1 at %0t", $time);
        #100; $display("Stored result to memory at 0x20 at %0t", $time);

         #20000 $finish;
    end

endmodule