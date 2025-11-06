module riscv_soc_top(
    input wire clk,
    input wire rstn,

    output logic [31:0] core0_nib_ex_data_o,
    output logic        core0_nib_ex_req_o,
    output logic [31:0] core0_nib_ex_addr_o,
    output logic        core0_nib_ex_we_o,
    output logic        core0_nib_pc_req_o,
    output logic [31:0] core0_nib_pc_addr_o
);

// NIB master interface signals

logic        core1_nib_ex_req_o;
logic [31:0] core1_nib_ex_addr_o;
logic [31:0] core1_nib_ex_data_o;
logic        core1_nib_ex_we_o;
logic        core1_nib_pc_req_o;
logic [31:0] core1_nib_pc_addr_o;

// NIB master read data and hold signals
logic [31:0] m0_rd_data_o;
logic        m0_hold_o;
logic [31:0] m1_rd_data_o;
logic [31:0] m2_rd_data_o;
logic [31:0] m3_rd_data_o;
logic        m3_hold_o;
logic [31:0] m4_rd_data_o;
logic [31:0] m5_rd_data_o;

// NIB slave interface signals
logic        s0_data_req_o;
logic [31:0] s0_addr_o;
logic [31:0] rd_ram_o;
logic        s0_wr_en_o;
logic [31:0] s0_wr_data_o;

logic        s1_data_req_o;
logic [31:0] s1_addr_o;
logic [31:0] rd_instr_o;
logic        s1_wr_en_o;
logic [31:0] s1_wr_data_o;

logic        s2_data_req_o;
logic [31:0] s2_addr_o;
logic [31:0] rd_scalar_o;
logic        s2_wr_en_o;
logic [31:0] s2_wr_data_o;

logic core_0_working;
logic core_1_working;
logic core_0_activate;
logic core_1_activate;

//实例化nib
nib u_nib(
    .clk           (clk           ),
    .rstn          (rstn          ),

    .core_0_bus_spare(core_0_bus_spare      ),
    .core_1_bus_spare(core_1_bus_spare      ),
    .core_0_activate (core_0_activate       ),
    .core_1_activate (core_1_activate       ),

    .m0_data_req_i (core0_nib_ex_req_o  ),
    .m0_addr_i     (core0_nib_ex_addr_o ),
    .m0_rd_data_o  (m0_rd_data_o        ),
    .m0_wr_en_i    (core0_nib_ex_we_o   ),
    .m0_wr_data_i  (core0_nib_ex_data_o ),
    .m0_hold_o     (m0_hold_o           ),

    .m1_data_req_i (core0_nib_pc_req_o  ),
    .m1_addr_i     (core0_nib_pc_addr_o ),
    .m1_rd_data_o  (m1_rd_data_o        ),
    .m1_wr_en_i    ('0                  ),
    .m1_wr_data_i  ('0                  ),

    .m2_data_req_i (core0_nib_pc_req_o  ),
    .m2_addr_i     (core0_nib_pc_addr_o ),
    .m2_rd_data_o  (m2_rd_data_o        ),
    .m2_wr_en_i    ('0                  ),
    .m2_wr_data_i  ('0                  ),

    .m3_data_req_i ('0  ),
    .m3_addr_i     ('0 ),
    .m3_rd_data_o  (m3_rd_data_o        ),
    .m3_wr_en_i    (core1_nib_ex_we_o   ),
    .m3_wr_data_i  (core1_nib_ex_data_o ),
    .m3_hold_o     (m3_hold_o           ),

    .m4_data_req_i ('0  ),
    .m4_addr_i     ('0 ),
    .m4_rd_data_o  (m4_rd_data_o        ),
    .m4_wr_en_i    ('0                  ),
    .m4_wr_data_i  ('0                  ),

    .m5_data_req_i ('0  ),
    .m5_addr_i     ('0 ),
    .m5_rd_data_o  (m5_rd_data_o        ),
    .m5_wr_en_i    ('0                  ),
    .m5_wr_data_i  ('0                  ),

    .s0_data_req_o (s0_data_req_o       ),
    .s0_addr_o     (s0_addr_o           ),
    .s0_rd_data_i  (rd_ram_o            ),
    .s0_wr_en_o    (s0_wr_en_o          ),
    .s0_wr_data_o  (s0_wr_data_o        ),

    .s1_data_req_o (s1_data_req_o       ),
    .s1_addr_o     (s1_addr_o           ),
    .s1_rd_data_i  (rd_instr_o          ),
    .s1_wr_en_o    (s1_wr_en_o          ),
    .s1_wr_data_o  (s1_wr_data_o        ),

    .s2_data_req_o (s2_data_req_o       ),
    .s2_addr_o     (s2_addr_o           ),
    .s2_rd_data_i  (rd_scalar_o         ),
    .s2_wr_en_o    (s2_wr_en_o          ),
    .s2_wr_data_o  (s2_wr_data_o        )
);

//实例化两个core
logic [1:0]  [31:0]core0_instr;
assign core0_instr[0] = m1_rd_data_o;
assign core0_instr[1] = m2_rd_data_o;

logic [1:0]  [31:0]core1_instr;
assign core1_instr[0] = m4_rd_data_o;
assign core1_instr[1] = m5_rd_data_o;



riscv_core #(
    .PC_INIT(32'h0000_0000)  // PC 初始地址
)    
core0(
    .clk                (clk            ),
    .rstn               (rstn           ),

    .nib_ex_addr_o      (core0_nib_ex_addr_o  ),
    .nib_ex_data_i      (m0_rd_data_o         ),
    .nib_ex_data_o      (core0_nib_ex_data_o  ),
    .nib_ex_req_o       (core0_nib_ex_req_o   ),
    .nib_ex_we_o        (core0_nib_ex_we_o    ),
    .nib_pc_addr_o      (core0_nib_pc_addr_o  ),
    .nib_pc_req_o       (core0_nib_pc_req_o   ),
    .nib_pc_data_i      (core0_instr          ),
    .nib_hold_req_i     ('0                   ),
    .core_bus_spare     (core_0_bus_spare     ),
    .core_activate      (core_0_activate      )
);


riscv_core #(
    .PC_INIT(32'h0000_1000)  // PC 初始地址
)    
core1(
    .clk                (clk            ),
    .rstn               (rstn           ),

    .nib_ex_addr_o      (core1_nib_ex_addr_o  ),
    .nib_ex_data_i      (m3_rd_data_o         ),
    .nib_ex_data_o      (core1_nib_ex_data_o  ),
    .nib_ex_req_o       (core1_nib_ex_req_o   ),
    .nib_ex_we_o        (core1_nib_ex_we_o    ),
    .nib_pc_addr_o      (core1_nib_pc_addr_o  ),
    .nib_pc_req_o       (core1_nib_pc_req_o   ),
    .nib_pc_data_i      (core1_instr          ),
    .nib_hold_req_i     (1            ),
    .core_bus_spare     (core_1_bus_spare     ),
    .core_activate      (core_1_activate      )
);

//例化slave
ram u_ram(
    .clk         (clk               ),
    .rstn        (rstn              ),

    .ram_req_i   (s0_data_req_o     ),
    .ram_addr_i  (s0_addr_o         ),
    .rd_ram_o    (rd_ram_o          ),
    .ram_we_i    (s0_wr_en_o        ),
    .ram_wdata_i (s0_wr_data_o      )
);

dual_rom u_dual_rom(
    .clk           (clk             ),
    .rstn          (rstn            ),

    .instr_req_i   (s1_data_req_o   ),
    .instr_addr_i  (s1_addr_o       ),
    .rd_instr_o    (rd_instr_o      ),
    .scalar_req_i  (s2_data_req_o   ),
    .scalar_addr_i (s2_addr_o       ),
    .rd_scalar_o   (rd_scalar_o     )
);






endmodule