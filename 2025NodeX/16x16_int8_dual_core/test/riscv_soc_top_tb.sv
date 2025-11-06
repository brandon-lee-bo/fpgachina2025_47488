`timescale 1ns/1ps
module riscv_soc_top_tb;

reg clk;
reg rstn;
logic [31:0] core0_nib_ex_data_o;
logic core0_nib_ex_req_o; 
logic [31:0] core0_nib_ex_addr_o;
logic core0_nib_ex_we_o;  
logic core0_nib_pc_req_o; 
logic [31:0] core0_nib_pc_addr_o;

riscv_soc_top u_riscv_soc_top(
    .clk                 (clk                 ),
    .rstn                (rstn                ),
    .core0_nib_ex_data_o (core0_nib_ex_data_o ),
    .core0_nib_ex_req_o  (core0_nib_ex_req_o  ),
    .core0_nib_ex_addr_o (core0_nib_ex_addr_o ),
    .core0_nib_ex_we_o   (core0_nib_ex_we_o   ),
    .core0_nib_pc_req_o  (core0_nib_pc_req_o  ),
    .core0_nib_pc_addr_o (core0_nib_pc_addr_o )
);

always begin
    #2.5 clk = ~clk; // 5ns 周期
end

// 测试流程
initial begin
    // 初始化信号
    $readmemb("instr_core0_init.txt", u_riscv_soc_top.u_dual_rom.dual_rom);
    $readmemh("scalar_core0_init.txt", u_riscv_soc_top.u_dual_rom.dual_rom, 2048);
    $readmemb("instr_core1_init.txt", u_riscv_soc_top.u_dual_rom.dual_rom, 1024);
    $readmemh("scalar_core1_init.txt", u_riscv_soc_top.u_dual_rom.dual_rom, 3072);
    $readmemh("external_mem_init.txt", u_riscv_soc_top.u_ram.ram);
    clk = 1'b0;
    rstn = 1'b0;
    // 复位
    #10 rstn = 1'b1;
    $display("Reset complete at %0t", $time);
    // 运行一段时间后结束仿真
    #10000;
    $finish;
end


endmodule