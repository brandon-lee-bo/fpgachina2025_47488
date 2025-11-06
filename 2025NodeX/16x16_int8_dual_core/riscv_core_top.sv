// RISC-V 向量处理器核顶层模块
//支持SPMM计算 接口遵循AXI4协议
import rvv_pkg::*;

module riscv_core #(
    parameter PC_INIT = 32'h0000_0000  // PC 初始地址   ;
    
) (
    input wire clk,                           // 时钟信号
    input wire rstn,                           // 复位信号
    output wire core_bus_spare,
    output wire core_activate,
    
    output wire [`MemAddrBus] nib_ex_addr_o,  // 内存访问地址（读/写） 已有
    output wire [`MemBus] nib_ex_data_o,      // 写入内存的数据 已有
    output wire nib_ex_we_o,//已有
    input wire [`MemBus] nib_ex_data_i,       // 从内存读取的数据 已有
    output nib_ex_req_o,//已有
    

    //取指端口单独作为一个master，scalar也单独作为一个端口
    //这两个主机不需要AW W B通道的内容，只需要配置AR和R通道，这两个主机的时序应该完全一样

    output wire [`MemAddrBus] nib_pc_addr_o,  // 取指地址 已有
    input wire [1:0] [`MemBus] nib_pc_data_i, // 取到的指令内容(vector & scalar) 已有
    output wire nib_pc_req_o,

    input wire nib_hold_req_i                // 总线暂停标志
);


////////////////////////////////////////////////////////////////
// 各模块输出信号

// pc_reg 模块信号
wire [`InstAddrBus] pc_addr_o;                  // 程序计数器地址

// if_id 模块信号
wire [1:0] [`InstBus] if_inst_o;              // 指令内容
wire [`InstAddrBus] if_inst_addr_o;           // 指令地址

// vid 模块信号
wire [`RegAddrBus] id_vs1_addr_o;             // 源向量寄存器 1 地址
wire [`RegAddrBus] id_vs2_addr_o;             // 源向量寄存器 2 地址
wire [`RegAddrBus] id_vd_addr_o;              // 目标向量寄存器地址
wire id_csr_write_o;                          // CSR 写使能
wire id_vex_en;                               // vex 使能
wire id_preserve_vl_o;                        // 保留向量长度标志
wire id_vrf_load_o;                           // 向量寄存器加载使能
wire id_vrf_write_o;                          // 向量寄存器写使能
wire [1:0] id_vd_data_src_o;                  // 目标向量数据来源选择
wire [1:0] id_vs3_addr_src_o;                 // vs3 地址来源选择
wire [3:0] id_pe_op_o;                        // 运算类型（加、减、乘等）
wire [1:0] id_operand_select_o;               // 操作数选择
wire id_pe_mul_us_o;                          // 乘法无符号控制
wire id_vlsu_en_o;                            // 向量加载/存储单元使能
wire id_vlsu_load_o;                          // 向量加载使能
wire id_vlsu_store_o;                         // 向量存储使能
wire id_vlsu_strided_o;                       // 跨距访问使能
wire [11:0] immediate_operand;                // 立即数操作数（由 vid 生成）todo
wire [31:0] scalar_operand;                   // 标量操作数（由 vid 生成）todo

// vrf 模块信号
wire [127:0] vs1_data;                        // 源向量寄存器 1 数据
wire [127:0] vs2_data;                        // 源向量寄存器 2 数据
wire [127:0] vs3_data;                        // 源向量寄存器 3 数据

// vex 模块信号
wire [127:0] arith_output;                    // 算术运算结果
wire comp_done;                               // GEMV 完成标志

// vlsu 模块信号（向量加载/存储单元）
wire [127:0] vlsu_wdata;                      // 向量存储数据
wire vlsu_ready;                              // 向量加载/存储准备好
wire vlsu_done;                               // 向量加载/存储完成
wire cycle_done;                            // 周期完成标志
wire data_req_o;                              // 内存请求
wire [`MemAddrBus]  data_addr_o;               // 内存地址
wire data_we_o;                               // 写使能
wire reduction;                               // 归约操作
wire [3:0] data_be_o;                         // 字节使能
wire [`MemBus] data_wdata_o;                  // 写入内存的数据
wire vrf_write_lsu;                       // LSU 向量寄存器写使能
wire [4:0] vs3_addr_vlsu;                     // LSU 提供的 vs3 地址

// vcsrs 模块信号
wire [7:0] vl;                                // 向量长度
wire [1:0] vsew;                              // 向量元素宽度
wire [1:0] vlmul;                             // 向量长度乘数

// ctrl 模块信号（流水线控制）
wire [3:0] hold_ctrls;                 // 流水线暂停标志
wire [3:0] vex_hold_req;              // vex 暂停请求
wire [3:0] vlsu_hold_req;            // vlsu 暂停请求
wire [3:0] vid_hold_req;            // vid 暂停请求

// 其他信号
logic [3:0] cycle_count;                      // 周期计数器，用于多周期操作
logic [3:0] max_load_cnt;                   // 最大加载计数器
logic [3:0] max_write_cnt;                  // 最大存储计数器

//spmm相关信号
wire id_spmm_load;
wire id_spmm_load_done;
wire ex_spmm_compute_done;
wire [15:0] ex_row_index_o;
wire ex_spmm_addr_ready_o;
wire id_spmm_write;
logic dma_data_req_o;
logic [31:0] dma_sparse_data_o;
logic [31:0]  dma_external_addr_o;
logic dma_load_buffer_en;
logic dma_sparse_store_done_o;
logic dma_data_out_flag;
logic [31:0] buf_sparse_data; // buffer中的稀疏矩阵数据
logic ex_index_cal_done_o;
logic [15:0] ex_row_index_dense_o;


logic buf_data_ready;
logic buf_load_en;
logic ex_spmm_add_done;
////////////////////////////////////////////////////////////////
// 信号生成连接

// NIB 接口连接
assign nib_ex_addr_o = external_addr_o;           // 输出：内存访问地址来自 vlsu
assign nib_ex_data_o = data_wdata_o;          // 输出：写入内存的数据来自 vlsu
assign nib_ex_req_o = data_req_o || dma_data_req_o;             // 输出：内存请求来自 vlsu或者dma
assign nib_ex_we_o = data_we_o;               // 输出：写使能来自 vlsu
assign nib_pc_addr_o = pc_addr_o;               // 输出：取指地址来自 pc_reg

logic [31:0] external_addr_o;
assign external_addr_o = dma_data_req_o? dma_external_addr_o: data_addr_o; // 外部地址选择


////////////////////////////////////////////////////////////////
// 模块例化

// 1. pc_reg 模块：生成指令地址
pc_reg #(
    .PC_INIT(PC_INIT)  // PC 初始地址
)
u_pc_reg (
    .pc_o(pc_addr_o),                           // 程序计数器地址
    .clk(clk),                                  // 时钟信号
    .rstn(rstn),                                // 复位信号
    .hold_flag_i(hold_ctrls[0]),                 // 流水线暂停标志
    .pc_req_o(nib_pc_req_o)
);


// 2. ctrl 模块：控制流水线暂停
ctrl u_ctrl (
    .hold_ctrl_o(hold_ctrls),   // 4位暂停[3:0]，高至低为vlsu,vex,vid,pc_reg
    .rstn(rstn),
    .hold_vex_req_i(vex_hold_req),    // 来自 vex 的 4 位暂停请求
    .hold_vid_req_i(vid_hold_req),    // 来自 vid 的 4 位暂停请求
    .hold_axi_req_i(nib_hold_req_i)   // 来自 AXI 总线的暂停请求
);


// 3. vcsrs 模块：向量配置状态寄存器
vcsrs u_vcsrs (
    .vl(vl),                                  // 向量长度
    .vsew(vsew),                              // 向量元素宽度
    .vlmul(vlmul),                            // 向量长度乘数

    .clk(clk),                                // 时钟信号
    .rstn(rstn),                              // 复位信号（低有效）
    .avl_in(scalar_operand),                  // 可用向量长度（假设使用标量操作数）
    .vtype_in(immediate_operand[7:0]),        // 向量类型（假设使用立即数低 8 位）
    .write(id_csr_write_o),                   // 写使能
    .preserve_vl(id_preserve_vl_o)           // 保留向量长度
);


// 4. if_id 模块：取指到译码的过渡
if_id u_if_id (
    .inst_o(if_inst_o),                       // 指令内容
    .inst_addr_o(if_inst_addr_o),             // 指令地址

    .clk(clk),                                // 时钟信号
    .rstn(rstn),                                // 复位信号
    .inst_i(nib_pc_data_i),                   // 从 AXI 总线取到的指令
    .inst_addr_i(pc_addr_o),                     // 指令地址
    .hold_flag_i(hold_ctrls[0])            // 流水线暂停标志
);

logic id_dma_store_en;
logic [7:0] dma_max_data_count_o;
logic id_load_index_o;
logic ex_index_ready_o;
logic id_dense_buf_write_en_o;
logic [5:0] id_dense_buf_write_addr_o;
logic id_dense_buf_read_en_o;
logic [1:0] id_dense_buf_data_source_o;
logic [5:0] id_dense_buf_read_addr_o;

logic [3:0] ex_compute_rows_id_o[8];
logic [3:0] ex_extra_rows_id_o[8];
logic [3:0] ex_sorted_top_rows_o [4];

// 5. vid 模块：向量指令译码
vid u_vid (
    //.instr_o(),                               // 流水指令备用  todo
    .nib_hold_req_i(nib_hold_req_i),
    .immediate_operand(immediate_operand),    // 立即数操作数
    .scalar_operand(scalar_operand),          // 标量操作数
    .vs1_addr(id_vs1_addr_o),                 // 源向量寄存器 1 地址
    .vs2_addr(id_vs2_addr_o),                 // 源向量寄存器 2 地址
    .vd_addr(id_vd_addr_o),                   // 目标向量寄存器地址
    .bus_spare(core_bus_spare),
    .core_activate(core_activate),

    .csr_write(id_csr_write_o),               // CSR 写使能
    .vex_en(id_vex_en),                       // vex 使能
    .preserve_vl(id_preserve_vl_o),           // 保留向量长度
    .vrf_write(id_vrf_write_o),               // 向量寄存器写使能 todo
    .vrf_load(id_vrf_load_o),               // 向量寄存器写使能 todo    

    .reduction(reduction),                    // 归约
    .cycle_count(cycle_count),                // 当前指令循环计数
    .max_load_cnt(max_load_cnt),              // 最大加载计数器
    .max_write_cnt(max_write_cnt),            // 最大存储计数器
    .vd_data_src(id_vd_data_src_o),           // vd寄存器数据来源
    .vs3_addr_src(id_vs3_addr_src_o),         // vs3寄存器地址来源
    .pe_op(id_pe_op_o),                       // PE操作+-*/
    .operand_select(id_operand_select_o),     // 操作数选择 （arith模块利用case来给pe_data赋值）


    .clk(clk),                                // 时钟信号
    .rstn(rstn),                              // 复位信号（低有效）    
    .hold_id(hold_ctrls[1]),                  // hold输入 todo
    .instr_i(if_inst_o),                      // 指令内容    
    .vl(8'd4),                                  // 向量长度   
    .vsew(2'd2),                              // 向量元素宽度    
    .vlmul(2'd1),                            // 向量长度乘数

    .vlsu_en_o(id_vlsu_en_o),                 // 向量加载/存储使能
    .vlsu_load_o(id_vlsu_load_o),             // 向量加载使能
    .vlsu_store_o(id_vlsu_store_o),           // 向量存储使能
    .vlsu_strided_o(id_vlsu_strided_o),       // 跨距访问使能,dma没有这个功能
    .vlsu_done_i(vlsu_done),                  // vlsu 完成

    .hold_req_o(vid_hold_req),                 // hold  todo
    
    .sparse_write(id_spmm_write),
    .sparse_load(id_spmm_load),
    .index_cal_done(ex_index_cal_done_o),
    .row_index_dense_i(ex_row_index_dense_o),
    .compute_row_data_num(ex_compute_row_data_num_o),
    .extra_load_num_i(ex_extra_load_num_o),
    .extra_rows_id(ex_extra_rows_id_o),
    .top_rows_id(ex_sorted_top_rows_o),
    .compute_rows_id_i(ex_compute_rows_id_o),

    .dense_buf_write_en_o(id_dense_buf_write_en_o),
    .dense_buf_write_addr_o(id_dense_buf_write_addr_o),
    .dense_buf_read_en_o(id_dense_buf_read_en_o),
    .dense_buf_read_addr_o(id_dense_buf_read_addr_o),
    .dense_buf_data_source_o(id_dense_buf_data_source_o),

    .row_index(ex_row_index_o), // 行索引
    .addr_ready(ex_spmm_addr_ready_o),  //后面仿真需要这个信号隔一段时间在拉高 持续
    .spmm_load_done(id_spmm_load_done),   //可以在顶部加上这个信号的输出 在tb里面也要加
    .spmm_compute_done(ex_spmm_compute_done), // SPMM 计算完成标志
    .load_index_o(id_load_index_o), //让vex内部的buf读出一个index给vid
    .load_index_ready_i(ex_index_ready_o),

    .dma_instr_valid_o(dma_instr_valid_o),
    .dma_max_data_cnt(dma_max_data_count_o),
    .dma_store_en(id_dma_store_en), //使能dma从外部获取下一个稀疏矩阵数据
    .dma_store_done(dma_sparse_store_done_o) // dma存储完成信号
);




// 6. vrf 模块：向量寄存器文件
// 数据选择
logic [127:0] vd_data;                         // 目标向量寄存器数据（通过选择器）
logic [4:0] vs3_addr;                          // vs3 地址（通过选择器）
always_comb begin
    if (vlsu_done| cycle_done | comp_done | id_dense_buf_read_en_o | id_vrf_write_o ) begin
    // 选择目标向量寄存器数据来源
    case (id_vd_data_src_o)
        2'b00: vd_data = vlsu_wdata;          // 来源：内存（vlsu）     VREG_WB_SRC_MEMORY
        2'b01: vd_data = dense_buf_read_data_o;        // 来源：dense_buffer
        //2'b10: vd_data = replicated_scalar;   // 来源：标量复制结果     VREG_WB_SRC_SCALAR
        2'b11: vd_data = arith_output;
        default: vd_data = '0;                // 默认
    endcase
    end else begin
        vd_data = '0;                         // 默认值
    end

    // 选择 vs3 地址来源
    case (id_vs3_addr_src_o)
        2'b00: vs3_addr = id_vd_addr_o;       // 来源：译码阶段         VS3_ADDR_SRC_DECODE
        2'b01: vs3_addr = vs3_addr_vlsu;      // 来源：vlsu            VS3_ADDR_SRC_VLSU
        default: vs3_addr = '0;               // 默认
    endcase
    

end

vrf u_vrf (
    .vs1_data(vs1_data),                      // 源向量寄存器 1 数据
    .vs2_data(vs2_data),                      // 源向量寄存器 2 数据
    .vs3_data(vs3_data),                      // 源向量寄存器 3 数据

    .vd_data(vd_data),                        // vd_data_src决定
    .vs1_addr_i(id_vs1_addr_o),               // vs1
    .vs2_addr_i(id_vs2_addr_o),               // vs2
    .vd_addr_i(vs3_addr),                     // maybe vs3 address
    .vsew(2'd2),                              // 向量元素宽度
    .vl(8'd4),                                  // 向量长度
    .vlmul(2'd1),                            // 向量长度乘数
    .max_load_cnt(max_load_cnt),            // 最大加载计数器
    .max_write_cnt(max_write_cnt),          // 最大存储计数器
    .reduction(reduction),                // 归约操作
    .clk(clk),                                // 时钟信号
    .rstn(rstn),                              // 复位信号（低有效）
    .write_en((vlsu_done & !id_vd_data_src_o)|cycle_done|id_vrf_write_o|id_dense_buf_read_en_o ),        // 写使能（来自 vid 或 vlsu）id_vrf_write_o  comp_done
    .load_en( id_vrf_load_o | id_vlsu_store_o)           // 加载使能  id_vlsu_load_o
);


logic [4:0] ex_extra_load_num_o;
logic [4:0] ex_compute_row_data_num_o;
// 7. vex 模块：向量执行单元
vex u_vex (
    .arith_output(arith_output),              // 算术运算结果
    .hold_req_o(vex_hold_req),                // hold请求
    .comp_done(comp_done),                    // GEMV 完成标志 TODO
    .nib_hold_i(nib_hold_req_i),

    .clk(clk),                                // 时钟信号
    .rstn(rstn),                              // 复位信号（低有效）
    .vex_en(id_vex_en),                       // vex 使能
    .vrf_load(id_vrf_load_o),               // 向量寄存器加载使能
    .vrf_write(id_vrf_write_o),               // 向量寄存器写使能
    .vs1_data_i(vs1_data),                      // vs1_data，取出32位数据，分别输入到4个lane中
    .vs2_data_i(vs2_data),                      // vs2_data
    .scalar_operand(scalar_operand),          // 标量操作数，用于标量-矢量运算
    .imm_operand(immediate_operand[4:0]),     // 立即数操作数，用于立即数运算

    .cal_stationary_done (ex_index_cal_done_o),
    .row_index_dense (ex_row_index_dense_o),

    .cycle_count(cycle_count),                // 周期计数器
    .max_cycle_cnt(max_load_cnt),            // 最大周期计数器
    .op(id_pe_op_o),                          // 运算类型
    .operand_select(id_operand_select_o),     // 操作数选择
    .vl(vl),                                  // 向量长度    
    .vsew(vsew),                              // 向量元素宽度
    .csr_load(id_spmm_load),               // CSR 加载使能
    .csr_write(0),               // CSR 写使能
    .spmm_compute_done(ex_spmm_compute_done), // SPMM 计算完成标志
    .spmm_load_done(id_spmm_load_done),
    .csr_data_i(buf_sparse_data),
    .row_index(ex_row_index_o),
    .load_row_index_i(id_load_index_o),
    .index_ready(ex_index_ready_o),
    .extra_load_num_o(ex_extra_load_num_o),
    .compute_row_data_num(ex_compute_row_data_num_o),
    .sorted_top_rows(ex_sorted_top_rows_o),
    .extra_rows_id(ex_extra_rows_id_o),
    .compute_rows_id(ex_compute_rows_id_o),
    .addr_ready(ex_spmm_addr_ready_o),         // 地址准备就绪信号
    
    .buf_data_ready(buf_data_ready), // buffer数据准备就绪信号
    .buf_load_en(buf_load_en)   // 从 buffer 加载稀疏矩阵数据使能
);



// 8. vlsu 模块：向量加载/存储单元
vlsu u_vlsu (
    .clk(clk),                                
    .rstn(rstn),                              
    .vl(8'd4),                                
    .vsew_i(2'd2),                            

    // id控制信号
    .vlsu_en_i(id_vlsu_en_o),                 // VLSU 使能信号
    .vlsu_load_i(id_vlsu_load_o),             // 向量加载使能
    .vlsu_store_i(id_vlsu_store_o),           // 向量存储使能
    .vlsu_strided_i(id_vlsu_strided_o),       // 跨步访问使能
    .vlsu_ready_o(vlsu_ready),                // VLSU 准备好信号，连接到 vid
    .vlsu_done_o(vlsu_done),                  // VLSU 操作完成信号，连接到 ctrl 和 vid
    .cycle_done(cycle_done),                // 周期完成信号，连接到vrf进行写入

    // 对外部存储
    .data_req_o(data_req_o),                  // 数据请求信号，
    .data_gnt_i(1'b1),                        // 数据授权信号 todo
    .data_rvalid_i(1'b1),                     // 数据读有效信号 todo 这里要改成axi_ready的信号
    .data_addr_o(data_addr_o),                // 数据地址，(axi_ex_addr_o)
    .data_we_o(data_we_o),                    // 数据写使能，(axi_ex_we_o)
    .data_be_o(data_be_o),                    // 字节使能信号
    .data_rdata_i(nib_ex_data_i),             // 内存读取数据，从axi获取
    .data_wdata_o(data_wdata_o),              // 内存写入数据

    .addr_data_i(scalar_operand),             // 加载/存储地址
    .stride_data_i(immediate_operand),        // 跨步访问步幅
    .reduction(reduction),                    // 归约操作

    .vr_addr_i(id_vd_addr_o),                 // decode输出的vd_addr，如果为VS3_ADDR_SRC_DECODE则成为vs3_addr
    .vs_rdata_i(dense_buf_read_data_o),       // 从dense buff读的数据，准备写回内存。
    .vs_wdata_o(vlsu_wdata),                  // 写回矢量寄存器的数据（128位宽）
    .vs3_addr_o(vs3_addr_vlsu),               // vs3_addr_vlsu，如果为VS3_ADDR_SRC_VLSU则成为vs3_addr择逻辑
    .vr_we_o(vrf_write_lsu)                   // 向量寄存器写使能
);


//9. sparse_buf 模块：稀疏矩阵缓冲
sparse_buf u_sparse_buf(
    .clk         (clk                ),
    .rstn        (rstn               ),

    .load_en     (buf_load_en        ),//从buffer读出数据给vex
    .store_en    (dma_data_out_flag  ),//从dma存储数据到buffer
    .store_data  (dma_sparse_data_o  ),//从dma取到的数据
    .sparse_data (buf_sparse_data    ),//输出稀疏矩阵数据
    .data_ready  (buf_data_ready     )//稀疏矩阵数据准备就绪信号
);


logic csr_write_req_o;
logic [31:0] csr_write_data_o;

//10. csr_dma 模块：从外部存储读取,不需要写功能
dma u_csr_dma(
    .clk                (clk                    ),
    .rstn               (rstn                   ),

    .store_mem_en       (id_dma_store_en        ),//要往dma中存入下一个稀疏矩阵数据
    .nib_hold_req_i     (nib_hold_req_i         ),
    .dma_mode_i         (1'b0                   ),//0表示sparse_buffer,1表示vrf
    .instr_valid_i      (dma_instr_valid_o      ),//指令有效信号
    .store_data         (nib_ex_data_i          ),//从外部存储传输进来的数据
    .addr_data_i        (if_inst_o[1]           ),//从内部产生的稀疏矩阵地址
    .data_req_o         (dma_data_req_o         ),// dma请求外部存储
    .data_out_flag      (dma_data_out_flag      ),//数据输出标志
    .sparse_store_done  (dma_sparse_store_done_o),// dma存储完成信号
    .buf_load_en        (buf_load_en            ),//从buffer load稀疏矩阵数据给vex
    .load_data_o        (dma_sparse_data_o      ),//输出的稀疏矩阵数据
    .external_addr      (dma_external_addr_o    ),//输出给外部存储的地址
    .max_data_count     (dma_max_data_count_o   ),
    .write_en           ('0                     ),
    .write_data         ('0                     ),
    .write_req_o        (csr_write_req_o        ),
    .write_data_o       (csr_write_data_o       )
);

//11. dense_buffer模块：从vlsu获取数据，暂存中间结果，输出数据给vrf
logic [127:0] dense_buf_write_data;
always_comb begin
    if (vlsu_done| cycle_done | comp_done ) begin
    // 选择目标向量寄存器数据来源
    case (id_dense_buf_data_source_o)
        2'b00: dense_buf_write_data = vlsu_wdata;          // 来源：内存（vlsu）     VREG_WB_SRC_MEMORY
        2'b01: dense_buf_write_data = arith_output;        // 来源：算术运算结果     VREG_WB_SRC_ARITH
        default: dense_buf_write_data = '0;                // 默认
    endcase
    end else begin
        dense_buf_write_data = '0;                         // 默认值
    end
end

logic [127:0] dense_buf_read_data_o;

dense_buf u_dense_buf(
    .clk                (clk            ),
    .rstn               (rstn           ),

    .write_en_i         (id_dense_buf_write_en_o      ),
    .write_addr_i       (id_dense_buf_write_addr_o    ),
    .write_data_i       (dense_buf_write_data         ),
    .read_en_i          ((id_dense_buf_read_en_o)),
    .read_addr_i        (id_dense_buf_read_addr_o     ),
    .read_data_o        (dense_buf_read_data_o        )
);




endmodule